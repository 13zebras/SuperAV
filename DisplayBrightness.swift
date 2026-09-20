import AppKit
import CoreGraphics
import Darwin
import Foundation

struct DisplayDescriptor {
	let id: CGDirectDisplayID
	let name: String
	let frame: CGRect
}

enum DisplayBrightnessError: LocalizedError {
	case frameworkUnavailable
	case symbolsUnavailable
	case invalidValue
	case readFailed(displayID: CGDirectDisplayID, status: Int32)
	case writeFailed(displayID: CGDirectDisplayID, status: Int32)

	var errorDescription: String? {
		switch self {
		case .frameworkUnavailable:
			return "macOS display brightness services are unavailable."
		case .symbolsUnavailable:
			return "This version of macOS does not expose display brightness control."
		case .invalidValue:
			return "Brightness must be between 0 and 100."
		case .readFailed(let displayID, let status):
			return "Could not read display \(displayID) brightness (status \(status))."
		case .writeFailed(let displayID, let status):
			return "Could not set display \(displayID) brightness (status \(status))."
		}
	}
}

@MainActor
final class DisplayBrightnessService {
	private typealias GetBrightnessFunction = @convention(c) (
		CGDirectDisplayID,
		UnsafeMutablePointer<Float>
	) -> Int32
	private typealias SetBrightnessFunction = @convention(c) (
		CGDirectDisplayID,
		Float
	) -> Int32

	private let frameworkHandle: UnsafeMutableRawPointer?
	private let getBrightnessFunction: GetBrightnessFunction?
	private let setBrightnessFunction: SetBrightnessFunction?

	init() {
		let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
		let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
		frameworkHandle = handle

		if let symbol = handle.flatMap({ dlsym($0, "DisplayServicesGetBrightness") }) {
			getBrightnessFunction = unsafeBitCast(symbol, to: GetBrightnessFunction.self)
		} else {
			getBrightnessFunction = nil
		}

		if let symbol = handle.flatMap({ dlsym($0, "DisplayServicesSetBrightness") }) {
			setBrightnessFunction = unsafeBitCast(symbol, to: SetBrightnessFunction.self)
		} else {
			setBrightnessFunction = nil
		}
	}

	var availabilityError: DisplayBrightnessError? {
		guard frameworkHandle != nil else {
			return .frameworkUnavailable
		}
		guard getBrightnessFunction != nil, setBrightnessFunction != nil else {
			return .symbolsUnavailable
		}
		return nil
	}

	func activeDisplays() -> [DisplayDescriptor] {
		NSScreen.screens
			.compactMap { screen in
				guard
					let screenNumber = screen.deviceDescription[
						NSDeviceDescriptionKey("NSScreenNumber")
					] as? NSNumber
				else {
					return nil
				}

				var name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
				if name.isEmpty {
					name = "Display"
				}
				return DisplayDescriptor(
					id: CGDirectDisplayID(screenNumber.uint32Value),
					name: name,
					frame: screen.frame
				)
			}
			.sorted { left, right in
				if left.frame.minX != right.frame.minX {
					return left.frame.minX < right.frame.minX
				}
				if left.frame.minY != right.frame.minY {
					return left.frame.minY < right.frame.minY
				}
				return left.id < right.id
			}
	}

	func readPercentage(for displayID: CGDirectDisplayID) throws -> Double {
		if let availabilityError {
			throw availabilityError
		}
		guard let getBrightnessFunction else {
			throw DisplayBrightnessError.symbolsUnavailable
		}

		var value: Float = 0
		let status = getBrightnessFunction(displayID, &value)
		guard status == 0 else {
			throw DisplayBrightnessError.readFailed(displayID: displayID, status: status)
		}
		guard value.isFinite else {
			throw DisplayBrightnessError.readFailed(displayID: displayID, status: status)
		}

		return min(max(Double(value) * 100, 0), 100)
	}

	func setPercentage(_ percentage: Double, for displayID: CGDirectDisplayID) throws {
		guard percentage.isFinite, (0 ... 100).contains(percentage) else {
			throw DisplayBrightnessError.invalidValue
		}
		if let availabilityError {
			throw availabilityError
		}
		guard let setBrightnessFunction else {
			throw DisplayBrightnessError.symbolsUnavailable
		}

		let status = setBrightnessFunction(displayID, Float(percentage / 100))
		guard status == 0 else {
			throw DisplayBrightnessError.writeFailed(displayID: displayID, status: status)
		}
	}
}
