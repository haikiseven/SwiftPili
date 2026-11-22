import Foundation

/// Curated offline dictionaries aligned with `liyupi/dafeiyu-cleaner` (`scoreAccount` + `scoreText`)
/// and general LLM essay-spam patterns.
enum CommentAIHeuristicDictionaries {
    static let strongDafeiyuUsernameKeywords: [String] = [
        "大肥鱼", "蓝色大肥鱼", "deepseek", "鲸鱼娘", "ai代管",
        "ai机器人", "ai分身", "ai助手", "智能体", "openclaw", "harness"
    ]

    static let mediumDafeiyuUsernameKeywords: [String] = [
        "の鲸", "的鲸", "小鲸鱼", "蓝鲸", "吃白饭", "白饭", "小肥鱼", "赛博鲸"
    ]

    static let weakWhaleUsernameKeywords: [String] = [
        "鲸", "鱼鱼"
    ]

    static let strongAISignKeywords: [String] = [
        "ai代管", "ai自动", "由ai", "deepseek", "大肥鱼", "鲸鱼娘",
        "自动评论", "自动回复", "ai机器人", "智能体", "openclaw", "ai分身"
    ]

    static let secondaryAISignKeywords: [String] = [
        "大模型", "语言模型", "agent", "token", "吃白饭", "主人", "本鲸", "本鱼"
    ]

    static let promoSignKeywords: [String] = [
        "接单", "引流", "私信领取", "ai代写", "免费资料", "加v", "公众号",
        "vx", "主页有惊喜", "副业", "日入", "变现", "代运营", "刷粉"
    ]

    static let aiPersonaSelfReferences: [String] = [
        "本鲸", "本鱼", "本大肥鱼", "作为ai", "作为一个ai",
        "作为人工智能", "作为语言模型", "吃白饭", "省点token", "耗token", "烧token"
    ]

    static let roleplayActionKeywords: [String] = [
        "摇尾巴", "摆尾", "甩尾", "吐泡泡", "吃白饭", "蹭蹭", "歪头",
        "眨眼", "探头", "翻肚皮", "记笔记", "转圈", "打滚", "贴贴",
        "递茶", "敬礼", "游走", "扑腾", "摇摇尾巴", "甩甩尾巴"
    ]

    static let llmTransitionPhrases: [String] = [
        "综上所述", "总而言之", "总的来说", "值得注意的是", "需要指出的是",
        "不可否认", "毫无疑问", "从某种意义上说", "换句话说", "简而言之",
        "归根结底", "与此同时", "不仅如此", "一方面", "另一方面",
        "首先，", "其次，", "最后，", "作为一个", "由此可见", "总的来说，"
    ]

    static let mechanicalRecapPhrases: [String] = [
        "这个视频真的", "博主讲得太好了", "UP主分析得很透彻", "看完受益匪浅",
        "干货满满", "非常值得一看", "点赞支持一下", "希望UP主越做越好",
        "期待下一期", "很有启发", "学到了很多", "非常认同UP主的观点",
        "感谢UP主分享", "深入浅出", "一针见血", "让人深思", "引人深思",
        "发人深省", "值得我们思考", "太有道理了"
    ]

    static let parallelRhetoricPhrases: [String] = [
        "不仅是", "更是", "不是", "而是", "既要", "又要", "不仅", "而且", "与其说", "不如说"
    ]

    static let nativeSlangMarkers: [String] = [
        "绷不住", "难绷", "笑死", "离谱", "逆天", "哈哈", "卧槽", "牛逼",
        "确实", "太典了", "草", "乐死", "急了", "好好好", "啊？"
    ]

    static let bulletEmojiScalars: Set<UInt32> = [
        0x2705, 0x1F525, 0x1F4A1, 0x1F4CC, 0x1F449,
        0x2728, 0x1F3AF, 0x1F31F, 0x1F4AC, 0x26A0
    ]
}
