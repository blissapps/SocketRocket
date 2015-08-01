//
//  IO.swift
//  SocketRocket
//
//  Created by Mike Lewis on 7/30/15.
//
//

import Foundation
import SystemShims

public struct CloseFlags : OptionSetType {
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }
    public let rawValue: UInt
    public static let Stop = CloseFlags(rawValue: DISPATCH_IO_STOP)
}

public typealias DataHandler = (done: Bool, data: dispatch_data_t, error: ErrorType?) -> Void
public typealias ErrorHandler = (error: ErrorType?) -> Void

public protocol IO {
    // Closes the IO. the callback will be called when finished. IO can only be closed once
    // I/Os only exist once they're open.
    func read(length: size_t, queue: Queue, handler: DataHandler)
    
    func write(data: dispatch_data_t, queue: Queue, handler: DataHandler)
    
    func close(queue: Queue, flags: CloseFlags)
}



public class RawIO: IO {
    private let channel: dispatch_io_t
    
    public init(channel: dispatch_io_t) {
        self.channel = channel
    }
    
    public convenience init(fd: dispatch_fd_t,
        cleanupQueue: Queue,
        callbackQueue: Queue,
        ioQueue: Queue,
        cleanupHandler: ErrorHandler) {
            let channel = dispatch_io_create(DISPATCH_IO_STREAM, fd, cleanupQueue.queue) { errorCode in
                cleanupHandler(error: NSError.fromErrorCode(errorCode))
            }
            
            dispatch_set_target_queue(channel, ioQueue.queue);

            self.init(channel: channel)
    }
    
    public func read(length: Int, queue: Queue, handler: DataHandler) {
        dispatch_io_read(channel, 0, length, queue.queue, dataHandlerToIoHandler(handler))
    }
    
    public func write(data: dispatch_data_t, queue: Queue, handler: DataHandler) {
        dispatch_io_write(channel, 0, data, queue.queue, dataHandlerToIoHandler(handler))
    }
    
    public func close(queue: Queue, flags: CloseFlags) {
        dispatch_io_close(channel, flags.rawValue)
    }
}


typealias IOFactory = (fd: dispatch_fd_t) -> IO

public class Listener {
    let workQueue: Queue
    let ioFactory: IOFactory
    var eventSource: dispatch_source_t!
    
    var closeHandler: ErrorHandler!
    
    private init(workQueue: Queue, ioFactory: IOFactory) {
        self.workQueue = workQueue
        self.ioFactory = ioFactory
    }
    
    
    /// Starts listening
    ///
    /// :param: queue queue callback is called on
    /// :param: callback Called when listening starts. AN error if it failed
    static func startListening(port: UInt16, address: String, workQueue: Queue, ioFactory: IOFactory, queue: Queue, callback: ErrorHandler) -> Listener {
        
        let l = Listener(workQueue: workQueue, ioFactory: ioFactory)
        
        return l
    }
    
    public func close(queue: Queue, handler: ErrorHandler) {
        workQueue.dispatchAsync {
            self.closeHandler = handler
            dispatch_source_cancel(self.eventSource)
            self.eventSource = nil
        }
    }
}

extension NSError {
    convenience init(osError: Int32) {
        self.init(domain: NSPOSIXErrorDomain, code: Int(osError), userInfo: nil)
    }
    
    static func fromErrorCode(osError: Int32) -> NSError? {
        if osError == 0 {
            return nil;
        }
        
        return NSError(osError: osError)
    }
}

private func dataHandlerToIoHandler(handler: DataHandler) -> dispatch_io_handler_t {
    return { done, data, errorCode in
        handler(done: done, data: data, error: NSError.fromErrorCode(errorCode))
    }
}

enum OSError: ErrorType {
    case OSError(status: Int32)
    
    static func throwIfNotSuccess(status: Int32) throws  {
        if status != 0 {
            throw OSError(status: status)
        }
    }
    
    // Same as above, but checks if less than 0, and uses errno as the varaible
    static func throwIfNotSuccessLessThan0(status: Int32) throws  {
        if status < 0 {
            throw OSError(status: errno)
        }
    }
}

public protocol SockAddr {
    init()
    
    mutating func setup(listenAddr: ListenType, listenPort: UInt16) throws
    
    static var size : Int {get}
    static var addressFamily: Int32 { get }
}

public enum ListenType {
    case Loopback
    case Any
    case IPV6Addr(address: String)
    case IPV4Addr(address: String)
    
}
extension sockaddr_in6: SockAddr {
    public mutating func setup(listenAddr: ListenType, listenPort: UInt16) throws {
        switch listenAddr {
        case .Any:
            self.sin6_addr = in6addr_any
        case let .IPV6Addr(address: address):
            try OSError.throwIfNotSuccess(inet_pton(self.dynamicType.addressFamily, address, &self.sin6_addr))
        case .IPV4Addr:
            fatalError("Cannot listen to IPV4Address in an ipv6 socket")
        case .Loopback:
            self.sin6_addr = in6addr_loopback
        }
        
        self.sin6_port = listenPort.bigEndian
        self.sin6_family = sa_family_t(self.dynamicType.addressFamily)
        self.sin6_len = UInt8(self.dynamicType.size)
    }

    public static let size = sizeof(sockaddr_in6)
    public static let addressFamily = AF_INET6
}

let INADDR_ANY = in_addr(s_addr: 0x00000000)
let INADDR_LOOPBACK4 = in_addr(s_addr: UInt32(0x7f000001).bigEndian)

extension sockaddr_in: SockAddr {
    public static let size = sizeof(sockaddr_in)
    public static let addressFamily = AF_INET
    
    public mutating func setup(listenAddr: ListenType, listenPort: UInt16) throws {
        switch listenAddr {
        case .Any:
            self.sin_addr = INADDR_ANY
        case let .IPV4Addr(address: address):
            try OSError.throwIfNotSuccess(inet_pton(self.dynamicType.addressFamily, address, &self.sin_addr))
        case .IPV6Addr:
            fatalError("Cannot listen to IPV6Address in an ipv4 socket")
        case .Loopback:
            self.sin_addr = INADDR_LOOPBACK4
        }
        
        self.sin_port = listenPort.bigEndian
        self.sin_family = sa_family_t(self.dynamicType.addressFamily)
        self.sin_len = UInt8(self.dynamicType.size)
    }
    
}


extension SockAddr {
//    func connect() {
//        AF_INET
//    }
}

protocol SocketProtocol {
    typealias AddrType: SockAddr
    
    var addr: AddrType { get }
    
}

let defaultBacklog: Int32 = 5

//sockaddr_in
public class Socket<T: SockAddr> : SocketProtocol {
    typealias AddrType = T
    
    var addr = AddrType()
    
    var fd: dispatch_fd_t = -1
    
    // Initializes as a nonblocking socket and starts listening. DOes not create a dispatch source
    public init(listenAddr: ListenType, listenPort: UInt16) throws {
        fd = socket(AddrType.addressFamily, SOCK_STREAM, IPPROTO_TCP)
        try OSError.throwIfNotSuccessLessThan0(fd)
        do {
            let flags = shim_fcntl(fd, F_GETFL, 0);
            try OSError.throwIfNotSuccessLessThan0(shim_fcntl(fd, F_SETFL, flags | O_NONBLOCK))
            
            
            var val: Int32 = 1;
            
            try OSError.throwIfNotSuccessLessThan0(setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &val, socklen_t(sizeofValue(val))))
            
            try OSError.throwIfNotSuccessLessThan0(setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &val, socklen_t(sizeofValue(val))))
            
            try addr.setup(listenAddr, listenPort: listenPort)
            
            try OSError.throwIfNotSuccessLessThan0(shim_bind(fd, &addr, addr.dynamicType.size))
            
            try OSError.throwIfNotSuccessLessThan0(listen(fd, defaultBacklog))
        } catch let e {
            close(fd)
            self.fd = -1
            throw e
        }
    }
    
    /// Cancel handler isn't guaranteed to dispatch on a specific queue
    /// Returns a block that starts the cancel
    public func startAccepting(workQueue: Queue, cancelHandler: () -> Void, acceptHandler:(fd: dispatch_fd_t) -> Void) -> (() -> Void) {
        precondition(fd >= 0)
        
        let eventSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, UInt(fd), 0, workQueue.queue)
        dispatch_source_set_event_handler(eventSource) {
            var remoteAddress = AddrType()
            var len = socklen_t(remoteAddress.dynamicType.size);
            
            let native: dispatch_fd_t = shim_accept(self.fd, &remoteAddress, &len)
            if native == -1 {
                return;
            }
            
            acceptHandler(fd: native)
        }
        
        dispatch_source_set_cancel_handler(eventSource) {
            precondition(self.fd >= 0)
            close(self.fd);
            self.fd = -1
            
            cancelHandler()
        }
        
        dispatch_resume(eventSource);
        
        return {
            dispatch_source_cancel(eventSource)
        }
    }
}


//extension DataHandler {
//    func wrap()  -> dispatch_io_handler_t {
//
//    }
//}
extension dispatch_data_t {
    var empty: Bool {
        get {
            return dispatch_data_empty === self
        }
    }
}