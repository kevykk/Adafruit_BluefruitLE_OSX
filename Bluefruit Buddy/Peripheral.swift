//
//  Bluefruit Buddy
//
//  Created by Kevin Kachikian on 8/23/15.
//  Copyright © 2015 Adafruit. All rights reserved.
//

import AppKit
import Foundation
import CoreBluetooth



private let DisconnectTimeOut: NSTimeInterval = 20																// The # secs within which advertising does not show up causes us to think the device has gone AWOL



// Data model for each found Peripheral
// Goes disabled (gray) after an X second timeout if no advertisement data is sent indicating the peripheral is out of range or has shut off or otherwise disconnected
class Peripheral: NSObject, CBPeripheralDelegate {																// Must subclass from NSObject so NSTimer works!
	
	enum GATT {																									// Records the Services and Characteristics returned by a Peripheral
		case Service(CBService)
		case Characteristic(CBCharacteristic)
	}
	var displayGATT: [GATT] = []																				// The Characteristic and Service data to display. NOTE: The service field in a Characteristic is unowned(unsafe) and does not maintain its Service information
	
	var detailsController: DetailsWindowController?																// The details window connected to this Peripheral
	
	private let manager: CBCentralManager
	let peripheral: CBPeripheral																				// Side note: The UUID identifier is assigned by the Mac and not the actual UUID on the Peripheral. It is not persisted across Mac reboot/power offs
	let advertisementData: [String : AnyObject]
	var RSSI: NSNumber {
		didSet {
			if RSSI != 127 {																					// 127 is used to indicate 'n/a' RSSI & is set when our autodisable timer fires
				restartAutodisableTimer()
			}
		}
	}
	
	private var delegate: BLEPeripheralListHandlerDelegate?
	var deviceDisabled = true {																					// Start in a disabled (unselectable) state b/c we are about to do a Services lookup
		didSet {
			delegate?.refreshPeripheralList()
		}
	}
	
	private var rememberedSeconds: NSTimeInterval = 0
	private var disableTimer: NSTimer?																			// A timer to disable Peripherals in the list that are not continuously reporting advertising packets (and that are not already connect to the Mac)
	
	private var allServices: [CBService]!
	private var serviceIdx = 0																					// Index into allServices
	private var allCharacteristicsForService: [CBCharacteristic]!
	private var characteristicIdx = 0																			// Index into allCharacteristics
	var completeDISdata = false																					// Logs status of if we have obtained all the characteristics for this device yet or not
	
	
	// MARK: -
	
	init(manager: CBCentralManager, peripheral: CBPeripheral, advertisementData: [String : AnyObject], RSSI: NSNumber, refreshDelegate: BLEPeripheralListHandlerDelegate) {
		
		self.manager = manager
		self.peripheral = peripheral
		self.advertisementData = advertisementData
		self.RSSI = RSSI
		self.delegate = refreshDelegate
		
		super.init()
		
	}
	
	
	deinit {
		
		disableTimer?.invalidate()
		
	}
	
	
	// CBPeripheralDelegate
	func peripheral(peripheral: CBPeripheral, didDiscoverServices error: NSError?) {
		
		if verboseConsoleLog { NSLog("didDiscoverServices: peripheral=\(peripheral)"); if error != nil { NSLog("ERROR=\(error!)") } }
		
		if peripheral.services == nil {																			// An error in Service discovery
			advance(peripheral)																					// Keep us going anyway
			return
		}
		
		allServices = peripheral.services!																		// Record all Services this Peripheral offers in case CB changes the order of discovered services (unlikely but not documented not to)
		serviceIdx = 0																							// Start discovering the 1st one
		
		handleCharacteristicDiscoveryForService(peripheral, aService: allServices[serviceIdx])					// Iterate through each Service and see what Characteristics it has
		
	}
	
	
	// Called for each Service
	func handleCharacteristicDiscoveryForService(peripheral: CBPeripheral, aService: CBService) {
		
		if verboseConsoleLog { NSLog("Discovered Service: \(aService), isPrimary=\(aService.isPrimary)") }
		
		displayGATT.append(.Service(aService))																	// Remember the Service
		
		peripheral.discoverCharacteristics(nil, forService: aService)											// Discover ALL the Characteristics for this Service. Chains to didDiscoverCharacteristicsForService
		
	}
	
	
	// CBPeripheralDelegate
	func peripheral(peripheral: CBPeripheral, didDiscoverCharacteristicsForService service: CBService, error: NSError?) {
		
		if verboseConsoleLog { NSLog("didDiscoverCharacteristicsForService: peripheral=\(peripheral), service=\(service)"); if error != nil { NSLog("ERROR=\(error!)") } }
		
		if peripheral.services == nil {																			// An error in Characteristic discovery
			advance(peripheral)																					// Keep us going anyway
			return
		}
		
		allCharacteristicsForService = service.characteristics!													// Record all Characteristics this Service offers in case CB changes the order of discovered Characteristics (unlikely but not documented not to)
		characteristicIdx = 0																					// Start discovering the 1st Characteristic's data
		
		handleValueAquisitionForCharacteristic(peripheral, characteristic: allCharacteristicsForService[characteristicIdx])	// Iterate through all the Characteristics for this Service and get their Values if readable
		
	}
	
	
	// Called for each Characteristic for each Service
	func handleValueAquisitionForCharacteristic(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
		
		if verboseConsoleLog { NSLog("Discovered Characteristic: \(characteristic) \(characteristic.properties) \(characteristic.UUID.characteristicNameForUUID())") }
		
		if characteristic.properties.rawValue & CBCharacteristicProperties.Read.rawValue != 0 {					// This Characteristic allows reading
			peripheral.readValueForCharacteristic(characteristic)												// Reads the value by chaining to didUpdateValueForCharacteristic
			peripheral.setNotifyValue(true, forCharacteristic: characteristic)									// Set up for any changes to the Characteristic. Also chains to didUpdateValueForCharacteristic
		} else {
			if verboseConsoleLog { NSLog("Characteristic does not support reading") }
			
			displayGATT.append(.Characteristic(characteristic))													// Remember for display
			
			advance(peripheral)																					// Can't read anything from it so advance to the next Characteristic or Service
		}
		
	}
	
	
	// CBPeripheralDelegate
	func peripheral(peripheral: CBPeripheral, didUpdateValueForCharacteristic characteristic: CBCharacteristic, error: NSError?) {
		
		if verboseConsoleLog {
			var byteString = "n/a"																				// Default in case of error
			if let value = characteristic.value { byteString = value.description }
			NSLog("didUpdateValueForCharacteristic: peripheral=\(peripheral)")
			NSLog("service=\(characteristic.service), characteristic=\(characteristic) \(characteristic.UUID.characteristicNameForUUID()), bytes=\(byteString) \"\(byteString.hexToPrintableString())\"")
			if error != nil { NSLog("ERROR=\(error!)") }
		}
		
		displayGATT.append(.Characteristic(characteristic))														// Remember for display
		delegate!.refreshPeripheralList()																		// Tell to refresh when new or updated data come in
		
		advance(peripheral)
		
	}
	
	
	// Acquire the next Characteristic for this Service or the next Service if all the Characteristics have been obtained
	// When all Services have been queried, disconnect from the Peripheral to allow it to advertise again
	func advance(peripheral: CBPeripheral) {
		
		characteristicIdx += 1
		if characteristicIdx < allCharacteristicsForService.count {												// Next Charactertistic
			handleValueAquisitionForCharacteristic(peripheral, characteristic: allCharacteristicsForService[characteristicIdx])
			return
		}
		
		serviceIdx += 1
		if serviceIdx < allServices.count {																		// If more services, discover the Characteristics
			handleCharacteristicDiscoveryForService(peripheral, aService: allServices[serviceIdx])
			return
		}
		
		// Done with all Services & all Characteristics
		manager.cancelPeripheralConnection(peripheral)															// Disconnect from the Peripheral so it will start advertising itself again
		
		allServices = nil																						// Free up (potentially memory if CB copy on write had happened)
		allCharacteristicsForService = nil
		
		startAutodisableTimer(seconds: DisconnectTimeOut)														// # of seconds of inactivity - no advertisement data - makes this Peripheral automatically go disabled (gray and unselectable)
		
		completeDISdata = true
		
	}
	
	
	private func startAutodisableTimer(seconds seconds: NSTimeInterval) {										// Create a timer that needs to be tickled every 'second' seconds otherwise it will fire
		
		rememberedSeconds = seconds
		restartAutodisableTimer()
		delegate!.refreshPeripheralList()
		
	}
	
	
	private func restartAutodisableTimer() {																	// 'Tickle' the timer (can be called from non-main threads)
		
		deviceDisabled = false
		
		delayRunOnMainQ(0) {																					// Timers MUST be instantiated on the main thread
			self.disableTimer?.invalidate()
			self.disableTimer = NSTimer.scheduledTimerWithTimeInterval(self.rememberedSeconds, target: self, selector: #selector(Peripheral.disablePeripheral), userInfo: nil, repeats: false)
		}
		
	}
	
	
	/* private */ func disablePeripheral() {																	// NSTimer target functions can't be private {:~(
		
		deviceDisabled = true
		RSSI = 127																								// Indicate to show n/a for RSSI
		
	}
	
	
	func supportsService(uuidString: String) -> Bool {
		
		if self.displayGATT.indexOf({
			switch $0 {																							// Syntactically unattractive, but amazing how Swift does the magic
			case let .Service(aServ): if aServ.UUID.UUIDString == uuidString { return true }
			case .Characteristic(_): return false
			}
			return false
		}) != nil {																								// Found the Service
			return true
		} else {
			return false
		}
		
	}
	
	
	class func findPeripheral(id: NSUUID) -> Peripheral {
		
		let periph = foundPeripherals.filter() { $0.peripheral.identifier == id }
		guard periph.count != 0 else { preconditionFailure("searched peripheral not located") }					// If we are searching for it, it must be in foundPeripherals, otherwise big problem...
		
		return periph[0]
		
	}
	
} // Peripheral

