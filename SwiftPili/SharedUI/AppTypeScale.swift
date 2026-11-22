import Foundation

enum AppTextRole: CaseIterable {
    case cardTitle
    case cardMeta
    case narrowCardTitle
    case narrowCardMeta
    case rowTitle
    case rowMeta
    case libraryRowTitle
    case libraryRowMeta
    case libraryRowFooter
    case shelfCardTitle
    case screenTitle
    case editorialTitle
    case screenOwner
    case screenSummary
    case screenStat
    case commentAuthor
    case commentBody
    case commentMeta
    case commentAction
    case overlayBadge
    case sectionTitle
    case profileTitle
    case messageTitle
    case messageBody
    case messageMeta
    case controlLabel
}

enum AppTextStyle {
    case title1, title2, title3, headline, body, callout, subheadline, footnote, caption, caption2

    var nominalPointSize: CGFloat {
        switch self {
        case .title1: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        }
    }
}

enum AppTypeScale {
    static func style(_ role: AppTextRole, isRegularWidth: Bool) -> AppTextStyle {
        switch role {
        case .cardTitle:
            isRegularWidth ? .body : .subheadline
        case .cardMeta:
            isRegularWidth ? .footnote : .caption
        case .narrowCardTitle:
            isRegularWidth ? .subheadline : .subheadline
        case .narrowCardMeta:
            isRegularWidth ? .caption : .caption
        case .rowTitle:
            isRegularWidth ? .callout : .callout
        case .rowMeta:
            isRegularWidth ? .footnote : .footnote
        case .libraryRowTitle:
            isRegularWidth ? .callout : .subheadline
        case .libraryRowMeta:
            isRegularWidth ? .caption : .caption
        case .libraryRowFooter:
            isRegularWidth ? .caption2 : .caption2
        case .shelfCardTitle:
            isRegularWidth ? .caption : .caption2
        case .screenTitle:
            isRegularWidth ? .title3 : .headline
        case .editorialTitle:
            isRegularWidth ? .title1 : .title2
        case .screenOwner:
            isRegularWidth ? .callout : .subheadline
        case .screenSummary:
            isRegularWidth ? .footnote : .caption
        case .screenStat:
            isRegularWidth ? .caption : .caption
        case .commentAuthor:
            isRegularWidth ? .callout : .subheadline
        case .commentBody:
            isRegularWidth ? .callout : .subheadline
        case .commentMeta:
            isRegularWidth ? .caption2 : .caption2
        case .commentAction:
            isRegularWidth ? .footnote : .footnote
        case .overlayBadge:
            isRegularWidth ? .caption2 : .caption2
        case .sectionTitle:
            isRegularWidth ? .headline : .headline
        case .profileTitle:
            isRegularWidth ? .title3 : .title3
        case .messageTitle:
            isRegularWidth ? .callout : .subheadline
        case .messageBody:
            isRegularWidth ? .callout : .subheadline
        case .messageMeta:
            isRegularWidth ? .caption2 : .caption2
        case .controlLabel:
            isRegularWidth ? .subheadline : .footnote
        }
    }
}

enum CommentMetrics {
    static func subReplyPointSize(isRegularWidth: Bool) -> CGFloat {
        AppTypeScale.style(.commentBody, isRegularWidth: isRegularWidth).nominalPointSize - 1
    }
}
