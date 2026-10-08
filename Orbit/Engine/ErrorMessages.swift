import Foundation
import Virtualization

enum ErrorMessages {
    /// Text to show for an error, or nil when it shouldn't be shown at all (the user cancelled).
    static func message(for error: Error) -> String? {
        if error is CancellationError { return nil }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled: return nil
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "You're offline. Connect to the internet and try again."
            case NSURLErrorTimedOut:
                return "The download server didn't respond. Try again in a moment."
            case NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile, NSURLErrorCannotMoveFile:
                return "There isn't enough free space to save the download. Free up space and try again."
            case NSURLErrorBadServerResponse, NSURLErrorResourceUnavailable, NSURLErrorFileDoesNotExist:
                return "The download isn't available right now. Try again later, or choose an image file from this Mac."
            default: break
            }
        }
        if ns.domain == VZErrorDomain {
            switch VZError.Code(rawValue: ns.code) {
            case .operationCancelled:
                return nil
            case .virtualMachineLimitExceeded:
                return "macOS allows at most two macOS virtual machines to run at the same time. Shut one down first."
            case .outOfDiskSpace:
                return "The disk holding your virtual machines is full. Free up space and try again."
            case .installationRequiresUpdate:
                return "This Mac needs a software update before it can install that version of macOS. Open System Settings → General → Software Update."
            case .restoreImageCatalogLoadFailed, .invalidRestoreImageCatalog, .noSupportedRestoreImagesInCatalog:
                return "Couldn't get the list of macOS versions from Apple. Check your internet connection, or choose a restore image (.ipsw) from this Mac."
            case .invalidRestoreImage, .restoreImageLoadFailed:
                return "That restore image can't be used. It may be damaged or not meant for Apple Silicon Macs."
            case .save:
                return "Couldn't save the machine's state. It keeps running; shut it down normally instead."
            case .restore:
                return "Couldn't resume the saved session, so the machine started fresh."
            default:
                break
            }
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return "The disk is full. Free up space and try again."
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) {
            return "The disk is full. Free up space and try again."
        }
        return error.localizedDescription
    }
}
