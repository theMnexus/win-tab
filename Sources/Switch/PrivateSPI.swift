import ApplicationServices
import CoreGraphics

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("CGSMoveWindowsToManagedSpace")
func CGSMoveWindowsToManagedSpace(_ cid: CGSConnectionID, _ windowIDs: CFArray, _ toSpace: CGSSpaceID)

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

// Process Manager is deprecated but still resolves; renamed to avoid clashing with the SDK declaration.
@_silgen_name("GetProcessForPID")
func SLGetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum SLPSMode {
    static let userGenerated: UInt32 = 0x200
}

@_silgen_name("_SLPSSetFrontProcessWithOptions")
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: UInt32) -> OSStatus

@_silgen_name("SLPSPostEventRecordTo")
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

#if DEBUG
// Window query iterator (the WindowServer's own per-Space window list, as yabai uses it).
@_silgen_name("SLSCopyWindowsWithOptionsAndTags")
func SLSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID, _ owner: UInt32, _ spaces: CFArray, _ options: UInt32, _ setTags: UnsafeMutablePointer<UInt64>, _ clearTags: UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?

@_silgen_name("SLSWindowQueryWindows")
func SLSWindowQueryWindows(_ cid: CGSConnectionID, _ windows: CFArray, _ count: Int32) -> Unmanaged<CFTypeRef>?

@_silgen_name("SLSWindowQueryResultCopyWindows")
func SLSWindowQueryResultCopyWindows(_ query: CFTypeRef) -> Unmanaged<CFTypeRef>?

@_silgen_name("SLSWindowIteratorAdvance")
func SLSWindowIteratorAdvance(_ iterator: CFTypeRef) -> Bool

@_silgen_name("SLSWindowIteratorGetWindowID")
func SLSWindowIteratorGetWindowID(_ iterator: CFTypeRef) -> UInt32

@_silgen_name("SLSWindowIteratorGetParentID")
func SLSWindowIteratorGetParentID(_ iterator: CFTypeRef) -> UInt32

@_silgen_name("SLSWindowIteratorGetTags")
func SLSWindowIteratorGetTags(_ iterator: CFTypeRef) -> UInt64

@_silgen_name("SLSWindowIteratorGetAttributes")
func SLSWindowIteratorGetAttributes(_ iterator: CFTypeRef) -> UInt64
#endif
