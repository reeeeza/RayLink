//
//  TunnelFileDescriptor.swift
//  V2Teh
//
//  Created by Reza Eskandari on 2026-08-31.
//

import Foundation
import Darwin

enum TunnelFileDescriptorError: LocalizedError {
    case notFound

    var errorDescription: String? {
        "Could not locate the Network Extension utun file descriptor."
    }
}

enum TunnelFileDescriptor {

    private static let sysprotoControl: Int32 = 2
    private static let utunOptIfName: Int32 = 2

    static func find() throws -> Int32 {

        for fd in 0...1024 {

            var buffer = [CChar](
                repeating: 0,
                count: Int(IFNAMSIZ)
            )

            var length = socklen_t(buffer.count)

            let result = buffer.withUnsafeMutableBytes {
                rawBuffer in

                getsockopt(
                    Int32(fd),
                    sysprotoControl,
                    utunOptIfName,
                    rawBuffer.baseAddress,
                    &length
                )
            }

            guard result == 0 else {
                continue
            }

            let name = buffer.withUnsafeBufferPointer {
                pointer -> String in

                guard let base = pointer.baseAddress else {
                    return ""
                }

                return String(cString: base)
            }

            if name.hasPrefix("utun") {
                return Int32(fd)
            }
        }

        throw TunnelFileDescriptorError.notFound
    }
}
