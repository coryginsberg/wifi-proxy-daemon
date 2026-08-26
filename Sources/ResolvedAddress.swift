import Foundation

struct ResolvedAddress {
    let family: Int32
    let socktype: Int32
    let protocolNumber: Int32
    let storage: [UInt8]
    let length: socklen_t

    init?(_ info: addrinfo) {
        guard let address = info.ai_addr, info.ai_addrlen > 0 else {
            return nil
        }

        family = info.ai_family
        socktype = info.ai_socktype
        protocolNumber = info.ai_protocol
        length = info.ai_addrlen
        storage = Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(address), count: Int(info.ai_addrlen)))
    }
}
