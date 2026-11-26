import Foundation

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
        case .alib: Descriptor("Alibaba Cloud", "upos-sz-mirroralib.bilivideo.com", .alibaba, .mainland)
        case .alio1: Descriptor("Alibaba Cloud", "upos-sz-mirroralio1.bilivideo.com", .alibaba, .mainland)
        case .estgoss: Descriptor("Alibaba Cloud", "upos-sz-estgoss.bilivideo.com", .alibaba, .mainland)
        case .cos: Descriptor("Tencent Cloud", "upos-sz-mirrorcos.bilivideo.com", .tencent, .mainland)
        case .cosb: Descriptor("Tencent Cloud", "upos-sz-mirrorcosb.bilivideo.com", .tencent, .mainland)
        case .coso1: Descriptor("Tencent Cloud", "upos-sz-mirrorcoso1.bilivideo.com", .tencent, .mainland)
        case .tfTx: Descriptor("Tencent Cloud", "upos-tf-all-tx.bilivideo.com", .tencent, .mainland)
        case .estgcos: Descriptor("Tencent Cloud", "upos-sz-estgcos.bilivideo.com", .tencent, .mainland)
        case .hw: Descriptor("Huawei Cloud", "upos-sz-mirrorhw.bilivideo.com", .huawei, .mainland)
        case .hwb: Descriptor("Huawei Cloud", "upos-sz-mirrorhwb.bilivideo.com", .huawei, .mainland)
        case .hwo1: Descriptor("Huawei Cloud", "upos-sz-mirrorhwo1.bilivideo.com", .huawei, .mainland)
        case .hw08c: Descriptor("Huawei Cloud", "upos-sz-mirror08c.bilivideo.com", .huawei, .mainland)
        case .hw08h: Descriptor("Huawei Cloud", "upos-sz-mirror08h.bilivideo.com", .huawei, .mainland)
        case .hw08ct: Descriptor("Huawei Cloud", "upos-sz-mirror08ct.bilivideo.com", .huawei, .mainland)
        case .tfHw: Descriptor("Huawei Cloud", "upos-tf-all-hw.bilivideo.com", .huawei, .mainland)
        case .estghw: Descriptor("Huawei Cloud", "upos-sz-estghw.bilivideo.com", .huawei, .mainland)
        case .upcdnbda2: Descriptor("Baidu Cloud", "upos-sz-upcdnbda2.bilivideo.com", .baidu, .mainland)
        case .mirrorbd: Descriptor("Baidu Cloud", "upos-sz-mirrorbd.bilivideo.com", .baidu, .mainland)
        case .mirrorbdb: Descriptor("Baidu Cloud", "upos-sz-mirrorbdb.bilivideo.com", .baidu, .mainland)
        case .mirrorbos: Descriptor("Baidu Cloud", "upos-sz-mirrorbos.bilivideo.com", .baidu, .mainland)
        case .mirror14b: Descriptor("Other", "upos-sz-mirror14b.bilivideo.com", .other, .mainland)
        case .mirrorzos: Descriptor("Other", "upos-sz-mirrorzos.bilivideo.com", .other, .mainland)
        case .cnTjCu0102: Descriptor("Other", "cn-tj-cu-01-02.bilivideo.com", .other, .mainland)
        case .cnTjCu0103: Descriptor("Other", "cn-tj-cu-01-03.bilivideo.com", .other, .mainland)
        case .aliov: Descriptor("Overseas", "upos-sz-mirroraliov.bilivideo.com", .overseas, .overseas)
        case .cosov: Descriptor("Overseas", "upos-sz-mirrorcosov.bilivideo.com", .overseas, .overseas)
        case .hwov: Descriptor("Overseas", "upos-sz-mirrorhwov.bilivideo.com", .overseas, .overseas)
        case .eqHk: Descriptor("Overseas", "cn-hk-eq-01-01.bilivideo.com", .overseas, .overseas)
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
