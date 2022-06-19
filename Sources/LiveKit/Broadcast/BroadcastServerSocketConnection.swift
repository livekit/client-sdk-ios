//
//  SocketConnection.swift
//  Broadcast Extension
//
//  Created by Alex-Dan Bumbu on 22/03/2021.
//  Copyright © 2021 Atlassian Inc. All rights reserved.
//

import Foundation
import Darwin
import CHeaders

class BroadcastServerSocketConnection: NSObject {
    
    private let streamDelegate: StreamDelegate
    
    private let filePath: String
    private var socketHandle: Int32 = -1
    private var address: sockaddr_un?

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    
    private var networkQueue: DispatchQueue?
    private var shouldKeepRunning = false

    init?(filePath path: String, streamDelegate: StreamDelegate) {
        filePath = path
        socketHandle = socket(AF_UNIX, SOCK_STREAM, 0)
        self.streamDelegate = streamDelegate

        guard socketHandle >= 0 else {
            logger.log(level: .debug, "failure: create socket")
            return nil
        }
        
    }

    func open() -> Bool {
        logger.log(level: .debug, "open socket connection")
        
        logger.log(level: .debug, "socket to \(filePath)")
        guard FileManager.default.fileExists(atPath: filePath) else {
            logger.log(level: .debug, "failure: socket file missing")
            return false
        }
      
        guard setupAddress() == true else {
            return false
        }
        
        guard connectSocket() == true else {
            return false
        }
        
        logger.log(level: .debug, "setupStreams")
        setupStreams()
        
        inputStream?.open()
        outputStream?.open()
        
        logger.log(level: .debug, "streams open")
        return true
    }

    func close() {
        unscheduleStreams()

        inputStream?.delegate = nil
        outputStream?.delegate = nil

        inputStream?.close()
        outputStream?.close()
        
        inputStream = nil
        outputStream = nil
        
        logger.log(level: .debug, "closing server socket")
        Darwin.close(socketHandle)
    }

    func writeToStream(buffer: UnsafePointer<UInt8>, maxLength length: Int) -> Int {
        outputStream?.write(buffer, maxLength: length) ?? 0
    }
}

private extension BroadcastServerSocketConnection {
  
    func setupAddress() -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX);
        guard filePath.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            logger.log(level: .debug, "failure: fd path is too long")
            return false
        }
        
        _ = filePath.withCString {
            unlink($0)
        }
        
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            filePath.withCString {
                strncpy(ptr, $0, filePath.count)
            }
        }
        
        address = addr
        return true
    }

    func connectSocket() -> Bool {
        guard var addr = address else {
            return false
        }
        
        let status = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketHandle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard status == noErr else {
            logger.log(level: .debug, "failure: \(status)")
            return false
        }
        
        return true
    }

    func setupStreams() {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketHandle, &readStream, &writeStream)

        inputStream = readStream?.takeRetainedValue()
        inputStream?.delegate = self.streamDelegate
        inputStream?.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))

        outputStream = writeStream?.takeRetainedValue()
        outputStream?.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))

        scheduleStreams()
    }
  
    func scheduleStreams() {
        shouldKeepRunning = true
        
        networkQueue = DispatchQueue.global(qos: .userInitiated)
        networkQueue?.async { [weak self] in
            self?.inputStream?.schedule(in: .current, forMode: .common)
            self?.outputStream?.schedule(in: .current, forMode: .common)
            RunLoop.current.run()
            
            var isRunning = false
                        
            repeat {
                isRunning = self?.shouldKeepRunning ?? false && RunLoop.current.run(mode: .default, before: .distantFuture)
            } while (isRunning)
        }
    }
    
    func unscheduleStreams() {
        networkQueue?.sync { [weak self] in
            self?.inputStream?.remove(from: .current, forMode: .common)
            self?.outputStream?.remove(from: .current, forMode: .common)
        }
        
        shouldKeepRunning = false
    }
}
