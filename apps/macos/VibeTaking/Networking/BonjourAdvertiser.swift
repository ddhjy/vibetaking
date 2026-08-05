import Foundation

final class BonjourAdvertiser: NSObject {
    static let serviceType = "_vibetaking._tcp."

    private var service: NetService?

    func start(port: UInt16) {
        stop()

        let name = Host.current().localizedName ?? "Mac"
        let service = NetService(
            domain: "local.",
            type: Self.serviceType,
            name: name,
            port: Int32(port)
        )
        service.delegate = self

        let txtRecord = NetService.data(fromTXTRecord: [
            "v": Data("1".utf8),
            "proto": Data("http".utf8),
        ])
        service.setTXTRecord(txtRecord)
        service.publish()
        self.service = service
    }

    func stop() {
        service?.stop()
        service = nil
    }
}

extension BonjourAdvertiser: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        print("Bonjour published: \(sender.name)\(sender.type) port \(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        print("Bonjour publish failed: \(errorDict)")
    }
}
