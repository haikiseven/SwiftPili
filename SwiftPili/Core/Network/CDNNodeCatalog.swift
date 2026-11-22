import Foundation

/// Immutable node metadata and sweep membership in service declaration order.
enum CDNNodeCatalog {
    enum SweepMembership: Equatable, Sendable {
        case none
        case mainland
        case overseas
    }

    struct Descriptor: Sendable {
        let labelKey: String.LocalizationValue
        let host: String?
        let provider: CDNProvider?
        let sweepMembership: SweepMembership

        /// Catalogue columns: localization key, fixed host, provider, sweep membership.
        init(
            _ labelKey: String.LocalizationValue,
            _ host: String?,
            _ provider: CDNProvider?,
            _ sweepMembership: SweepMembership
        ) {
            self.labelKey = labelKey
            self.host = host
            self.provider = provider
            self.sweepMembership = sweepMembership
        }
    }

    static subscript(_ service: CDNService) -> Descriptor {
        switch service {
        case .baseUrl: Descriptor("Base URL", nil, nil, .none)
        case .backupUrl: Descriptor("Backup URL", nil, nil, .none)
        case .ali: Descriptor("Alibaba Cloud", "upos-sz-mirrorali.bilivideo.com", .alibaba, .mainland)
        case .alib: Descriptor("Alibaba Cloud B", "upos-sz-mirroralib.bilivideo.com", .alibaba, .mainland)
        case .alio1: Descriptor("Alibaba Cloud O1", "upos-sz-mirroralio1.bilivideo.com", .alibaba, .mainland)
        case .cos: Descriptor("Tencent Cloud", "upos-sz-mirrorcos.bilivideo.com", .tencent, .mainland)
        case .cosb: Descriptor("Tencent Cloud VOD", "upos-sz-mirrorcosb.bilivideo.com", .tencent, .mainland)
        case .coso1: Descriptor("Tencent Cloud O1", "upos-sz-mirrorcoso1.bilivideo.com", .tencent, .mainland)
        case .hw: Descriptor("Huawei Cloud", "upos-sz-mirrorhw.bilivideo.com", .huawei, .mainland)
        case .hwb: Descriptor("Huawei Cloud B", "upos-sz-mirrorhwb.bilivideo.com", .huawei, .mainland)
        case .hwo1: Descriptor("Huawei Cloud O1", "upos-sz-mirrorhwo1.bilivideo.com", .huawei, .mainland)
        case .hw08c: Descriptor("Huawei 08c", "upos-sz-mirror08c.bilivideo.com", .huawei, .mainland)
        case .hw08h: Descriptor("Huawei 08h", "upos-sz-mirror08h.bilivideo.com", .huawei, .mainland)
        case .hw08ct: Descriptor("Huawei 08ct", "upos-sz-mirror08ct.bilivideo.com", .huawei, .mainland)
        case .tfHw: Descriptor("Huawei (TF)", "upos-tf-all-hw.bilivideo.com", .huawei, .mainland)
        case .tfTx: Descriptor("Tencent (TF)", "upos-tf-all-tx.bilivideo.com", .tencent, .mainland)
        case .estgoss: Descriptor("Tencent OSS", "upos-sz-estgoss.bilivideo.com", .alibaba, .mainland)
        case .estgcos: Descriptor("Tencent COS", "upos-sz-estgcos.bilivideo.com", .tencent, .mainland)
        case .estghw: Descriptor("Huawei ESTG", "upos-sz-estghw.bilivideo.com", .huawei, .mainland)
        case .upcdnbda2: Descriptor("Baidu Cloud", "upos-sz-upcdnbda2.bilivideo.com", .other, .mainland)
        case .aliov: Descriptor("Alibaba Overseas", "upos-sz-mirroraliov.bilivideo.com", .overseas, .overseas)
        case .cosov: Descriptor("Tencent Overseas", "upos-sz-mirrorcosov.bilivideo.com", .overseas, .overseas)
        case .hwov: Descriptor("Huawei Overseas", "upos-sz-mirrorhwov.bilivideo.com", .overseas, .overseas)
        case .eqHk: Descriptor("Equinix Hong Kong", "cn-hk-eq-01-01.bilivideo.com", .overseas, .overseas)
        case .mirrorbd: Descriptor("UPOS Mirror BD", "upos-sz-mirrorbd.bilivideo.com", .other, .mainland)
        case .mirrorbdb: Descriptor("UPOS Mirror BDB", "upos-sz-mirrorbdb.bilivideo.com", .other, .mainland)
        case .mirror14b: Descriptor("UPOS Mirror 14B", "upos-sz-mirror14b.bilivideo.com", .other, .mainland)
        case .mirrorzos: Descriptor("UPOS Mirror ZOS", "upos-sz-mirrorzos.bilivideo.com", .other, .mainland)
        case .mirrorbos: Descriptor("UPOS Mirror BOS", "upos-sz-mirrorbos.bilivideo.com", .other, .mainland)
        case .cnTjCu0102: Descriptor("CN-TJ-CU Node 01-02", "cn-tj-cu-01-02.bilivideo.com", .other, .mainland)
        case .cnTjCu0103: Descriptor("CN-TJ-CU Node 01-03", "cn-tj-cu-01-03.bilivideo.com", .other, .mainland)
        }
    }

    static var services: [CDNService] { CDNService.allCases }

    static var mainlandServices: [CDNService] {
        services.filter { CDNNodeCatalog[$0].sweepMembership == .mainland }
    }

    static var overseasServices: [CDNService] {
        services.filter { CDNNodeCatalog[$0].sweepMembership == .overseas }
    }
}
