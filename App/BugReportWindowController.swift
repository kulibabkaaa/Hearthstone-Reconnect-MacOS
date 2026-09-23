import AppKit
import ImageIO
import UniformTypeIdentifiers

private final class BugReportCardView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    updateAppearance()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  private func updateAppearance() {
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.borderColor =
      NSColor.separatorColor.withAlphaComponent(0.24).cgColor
    layer?.backgroundColor =
      NSColor.controlBackgroundColor.withAlphaComponent(0.36).cgColor
  }
}

private struct BugReportAttachment {
  let id = UUID()
  let url: URL
  let name: String
  let preview: NSImage
}

private enum BugReportImageSource {
  case file(URL)
  case encoded(Data)
}

private struct BugReportImageInput {
  let source: BugReportImageSource
  let name: String
}

private enum BugReportImageProcessor {
  struct PreparedImage {
    let image: NSImage
    let jpeg: Data
  }

  static func isSupported(_ source: BugReportImageSource) -> Bool {
    (try? validatedImageSource(for: source)) != nil
  }

  static func prepare(_ source: BugReportImageSource) throws
    -> PreparedImage
  {
    let imageSource = try validatedImageSource(for: source)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: 2_560,
    ]
    guard
      let cgImage = CGImageSourceCreateThumbnailAtIndex(
        imageSource,
        0,
        options as CFDictionary
      )
    else {
      throw CocoaError(.fileReadCorruptFile)
    }

    let size = NSSize(
      width: cgImage.width,
      height: cgImage.height
    )
    let image = NSImage(cgImage: cgImage, size: size)
    let flattened = NSImage(size: size)
    flattened.lockFocus()
    NSColor.black.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.draw(
      in: NSRect(origin: .zero, size: size),
      from: NSRect(origin: .zero, size: size),
      operation: .sourceOver,
      fraction: 1
    )
    flattened.unlockFocus()

    guard
      let tiff = flattened.tiffRepresentation,
      let representation = NSBitmapImageRep(data: tiff),
      let jpeg = representation.representation(
        using: .jpeg,
        properties: [.compressionFactor: 0.82]
      ),
      jpeg.count <= BugReportContent.maximumImageBytes
    else {
      throw CocoaError(.fileWriteOutOfSpace)
    }
    return PreparedImage(image: image, jpeg: jpeg)
  }

  private static func validatedImageSource(
    for source: BugReportImageSource
  ) throws -> CGImageSource {
    let byteCount: Int
    let imageSource: CGImageSource?
    switch source {
    case .file(let url):
      let values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .fileSizeKey]
      )
      guard
        values.isRegularFile == true,
        let fileSize = values.fileSize
      else {
        throw CocoaError(.fileReadInvalidFileName)
      }
      byteCount = fileSize
      imageSource = CGImageSourceCreateWithURL(
        url as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary
      )
    case .encoded(let data):
      byteCount = data.count
      imageSource = CGImageSourceCreateWithData(
        data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary
      )
    }

    guard
      byteCount > 0,
      byteCount <= BugReportContent.maximumSourceImageBytes,
      let imageSource,
      CGImageSourceGetCount(imageSource) > 0,
      let typeIdentifier = CGImageSourceGetType(imageSource),
      UTType(typeIdentifier as String)?.conforms(to: .image) == true,
      let properties = CGImageSourceCopyPropertiesAtIndex(
        imageSource,
        0,
        nil
      ) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?
        .intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?
        .intValue,
      BugReportContent.acceptsSourceImage(
        byteCount: byteCount,
        pixelWidth: width,
        pixelHeight: height
      )
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return imageSource
  }
}

private final class BugReportAttachmentPreview: NSView {
  let attachmentID: UUID
  var onRemove: ((UUID) -> Void)?

  init(attachment: BugReportAttachment) {
    attachmentID = attachment.id
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.borderColor =
      NSColor.separatorColor.withAlphaComponent(0.32).cgColor
    layer?.backgroundColor =
      NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
    toolTip = attachment.name
    setAccessibilityLabel("Attached image: \(attachment.name)")

    let imageView = NSImageView(image: attachment.preview)
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.wantsLayer = true
    imageView.layer?.cornerRadius = 6
    imageView.layer?.cornerCurve = .continuous
    imageView.layer?.masksToBounds = true

    let nameLabel = NSTextField(labelWithString: attachment.name)
    nameLabel.font = .systemFont(ofSize: 10)
    nameLabel.textColor = .secondaryLabelColor
    nameLabel.lineBreakMode = .byTruncatingMiddle
    nameLabel.alignment = .center

    let removeButton = HoverButton(
      title: "",
      target: self,
      action: #selector(removeAttachment)
    )
    removeButton.image = NSImage(
      systemSymbolName: "xmark.circle.fill",
      accessibilityDescription: nil
    )
    removeButton.bezelStyle = .circular
    removeButton.contentTintColor = .systemRed
    removeButton.toolTip = "Remove \(attachment.name)"
    removeButton.setAccessibilityLabel("Remove \(attachment.name)")

    for view in [imageView, nameLabel, removeButton] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 92),
      heightAnchor.constraint(equalToConstant: 86),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      imageView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      imageView.heightAnchor.constraint(equalToConstant: 58),
      nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      nameLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
      removeButton.widthAnchor.constraint(equalToConstant: 22),
      removeButton.heightAnchor.constraint(equalToConstant: 22),
      removeButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
      removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  @objc private func removeAttachment() {
    onRemove?(attachmentID)
  }
}

private final class BugReportDescriptionTextView: NSTextView {
  var canAcceptImages: (() -> Bool)?
  var onAttachImages: (([BugReportImageInput]) -> Void)?

  private var isShowingImageDropTarget = false {
    didSet {
      guard oldValue != isShowingImageDropTarget else { return }
      needsDisplay = true
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    registerForDraggedTypes([
      .fileURL,
      .png,
      .tiff,
      NSPasteboard.PasteboardType(UTType.image.identifier),
    ])
  }

  override func paste(_ sender: Any?) {
    if attachImages(from: .general, fallbackName: "Pasted Image") {
      return
    }
    super.paste(sender)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(
      [.command, .option, .control, .shift]
    )
    guard modifiers == .command,
      let key = event.charactersIgnoringModifiers?.lowercased()
    else {
      return super.performKeyEquivalent(with: event)
    }
    switch key {
    case "v":
      if !attachImages(from: .general, fallbackName: "Pasted Image") {
        super.paste(nil)
      }
      return true
    case "c":
      super.copy(nil)
      return true
    case "x":
      super.cut(nil)
      return true
    case "a":
      super.selectAll(nil)
      return true
    default:
      return super.performKeyEquivalent(with: event)
    }
  }

  override func draggingEntered(
    _ sender: NSDraggingInfo
  ) -> NSDragOperation {
    guard canAcceptImages?() != false,
      containsImages(sender.draggingPasteboard)
    else {
      isShowingImageDropTarget = false
      return []
    }
    isShowingImageDropTarget = true
    return .copy
  }

  override func draggingUpdated(
    _ sender: NSDraggingInfo
  ) -> NSDragOperation {
    isShowingImageDropTarget ? .copy : []
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    isShowingImageDropTarget = false
  }

  override func prepareForDragOperation(
    _ sender: NSDraggingInfo
  ) -> Bool {
    canAcceptImages?() != false
      && containsImages(sender.draggingPasteboard)
  }

  override func performDragOperation(
    _ sender: NSDraggingInfo
  ) -> Bool {
    defer { isShowingImageDropTarget = false }
    return attachImages(
      from: sender.draggingPasteboard,
      fallbackName: "Dropped Image"
    )
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard isShowingImageDropTarget else { return }

    let targetRect = visibleRect.insetBy(dx: 7, dy: 7)
    let targetPath = NSBezierPath(
      roundedRect: targetRect,
      xRadius: 9,
      yRadius: 9
    )
    NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
    targetPath.fill()
    NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
    targetPath.lineWidth = 2
    targetPath.setLineDash([7, 5], count: 2, phase: 0)
    targetPath.stroke()

    let message = "Drop images here" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
      .foregroundColor: NSColor.white,
    ]
    let messageSize = message.size(withAttributes: attributes)
    let messageRect = NSRect(
      x: targetRect.midX - messageSize.width / 2 - 11,
      y: targetRect.minY + 10,
      width: messageSize.width + 22,
      height: messageSize.height + 8
    )
    NSColor.controlAccentColor.setFill()
    NSBezierPath(
      roundedRect: messageRect,
      xRadius: 7,
      yRadius: 7
    ).fill()
    message.draw(
      at: NSPoint(
        x: messageRect.midX - messageSize.width / 2,
        y: messageRect.midY - messageSize.height / 2
      ),
      withAttributes: attributes
    )
  }

  private func attachImages(
    from pasteboard: NSPasteboard,
    fallbackName: String
  ) -> Bool {
    let inputs = imageInputs(
      from: pasteboard,
      fallbackName: fallbackName
    )
    guard !inputs.isEmpty else {
      return false
    }
    // Consume image pasteboard content even when the attachment limit blocks
    // it, so AppKit never inserts a Finder path into the description.
    onAttachImages?(inputs)
    return true
  }

  private func containsImages(_ pasteboard: NSPasteboard) -> Bool {
    !imageInputs(from: pasteboard, fallbackName: "Image").isEmpty
  }

  private func imageInputs(
    from pasteboard: NSPasteboard,
    fallbackName: String
  ) -> [BugReportImageInput] {
    let fileURLs = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] ?? []
    let fileInputs = fileURLs.compactMap { url -> BugReportImageInput? in
      let input = BugReportImageInput(
        source: .file(url),
        name: url.lastPathComponent
      )
      return BugReportImageProcessor.isSupported(input.source)
        ? input
        : nil
    }
    if !fileInputs.isEmpty {
      return fileInputs
    }

    for type in pasteboard.types ?? [] {
      guard
        let uniformType = UTType(type.rawValue),
        uniformType.conforms(to: .image),
        let data = pasteboard.data(forType: type),
        data.count <= BugReportContent.maximumSourceImageBytes
      else {
        continue
      }
      let input = BugReportImageInput(
        source: .encoded(data),
        name: fallbackName
      )
      if BugReportImageProcessor.isSupported(input.source) {
        return [input]
      }
    }
    return []
  }
}

final class BugReportWindowController: NSWindowController, NSTextViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
  private static let compactWindowHeight: CGFloat = 600
  private static let previewWindowHeight: CGFloat = 675

  private let client = BugReportClient()
  private let descriptionTextView = BugReportDescriptionTextView()
  private let replyEmailField = NSTextField()
  private let characterCountLabel = NSTextField(
    labelWithString: "0 / \(BugReportContent.maximumDescriptionLength)"
  )
  private let emptyAttachmentLabel = NSTextField(
    labelWithString: "No images selected"
  )
  private let attachmentPreviewStack = NSStackView()
  private let attachmentPreviewScrollView = NSScrollView()
  private let chooseImageButton = HoverButton(
    title: "Add Images…",
    target: nil,
    action: nil
  )
  private let submitButton = HoverButton(
    title: "Submit",
    target: nil,
    action: nil
  )
  private let cancelButton = HoverButton(
    title: "Cancel",
    target: nil,
    action: nil
  )
  private let statusLabel = NSTextField(labelWithString: "")

  private var attachments: [BugReportAttachment] = []
  private var submissionTask: Task<Void, Never>?
  private var isSubmitting = false
  private var formContentView: NSView?
  private var successContentView: NSView?
  private lazy var successSound: NSSound? = {
    guard let url = Bundle.main.url(
      forResource: "BugReportSuccess",
      withExtension: "mp3"
    ) else {
      return nil
    }
    return NSSound(contentsOf: url, byReference: true)
  }()

  init() {
    let window = NSWindow(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: 500,
        height: Self.compactWindowHeight
      ),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Report a Bug"
    window.center()
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    buildInterface()
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    submissionTask?.cancel()
    removeTemporaryAttachments()
  }

  func present() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeFirstResponder(descriptionTextView)
  }

  private func buildInterface() {
    guard let contentView = window?.contentView else { return }

    let appIcon = NSImageView(image: NSApp.applicationIconImage)
    appIcon.imageScaling = .scaleProportionallyUpOrDown
    appIcon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      appIcon.widthAnchor.constraint(equalToConstant: 42),
      appIcon.heightAnchor.constraint(equalToConstant: 42),
    ])

    let title = NSTextField(labelWithString: "Report a Bug")
    title.font = .systemFont(ofSize: 21, weight: .semibold)

    let header = NSStackView(views: [appIcon, title])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 12

    let descriptionTitle = NSTextField(
      labelWithString: "What happened?"
    )
    descriptionTitle.font = .systemFont(
      ofSize: 16,
      weight: .semibold
    )

    let explanation = NSTextField(
      wrappingLabelWithString:
        "Describe what went wrong and what you expected instead."
    )
    explanation.textColor = .secondaryLabelColor
    explanation.maximumNumberOfLines = 2

    descriptionTextView.font = .systemFont(ofSize: 13)
    descriptionTextView.isRichText = false
    descriptionTextView.isAutomaticQuoteSubstitutionEnabled = false
    descriptionTextView.isAutomaticDashSubstitutionEnabled = false
    descriptionTextView.delegate = self
    descriptionTextView.textContainerInset = NSSize(width: 8, height: 8)
    descriptionTextView.setAccessibilityLabel("Bug description")
    descriptionTextView.canAcceptImages = { [weak self] in
      guard let self else { return false }
      return !self.isSubmitting
        && self.attachments.count < BugReportContent.maximumImageCount
    }
    descriptionTextView.onAttachImages = { [weak self] inputs in
      self?.attachImages(inputs)
    }

    let descriptionScrollView = NSScrollView()
    descriptionScrollView.hasVerticalScroller = true
    descriptionScrollView.borderType = .noBorder
    descriptionScrollView.drawsBackground = true
    descriptionScrollView.backgroundColor = .textBackgroundColor
    descriptionScrollView.wantsLayer = true
    descriptionScrollView.layer?.cornerRadius = 8
    descriptionScrollView.layer?.cornerCurve = .continuous
    descriptionScrollView.layer?.borderWidth = 1
    descriptionScrollView.layer?.borderColor =
      NSColor.separatorColor.withAlphaComponent(0.32).cgColor
    descriptionScrollView.documentView = descriptionTextView
    descriptionScrollView.heightAnchor.constraint(equalToConstant: 145)
      .isActive = true

    let minimumLengthLabel = NSTextField(
      labelWithString: "Minimum \(BugReportContent.minimumDescriptionLength) characters"
    )
    minimumLengthLabel.font = .systemFont(ofSize: 11)
    minimumLengthLabel.textColor = .secondaryLabelColor
    characterCountLabel.font = .systemFont(ofSize: 11)
    characterCountLabel.textColor = .secondaryLabelColor
    characterCountLabel.alignment = .right
    let counterSpacer = NSView()
    counterSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let counterRow = NSStackView(
      views: [minimumLengthLabel, counterSpacer, characterCountLabel]
    )
    counterRow.orientation = .horizontal
    counterRow.alignment = .centerY

    let descriptionStack = NSStackView(
      views: [
        descriptionTitle,
        explanation,
        descriptionScrollView,
        counterRow,
      ]
    )
    descriptionStack.orientation = .vertical
    descriptionStack.alignment = .leading
    descriptionStack.spacing = 8
    for view in [
      explanation,
      descriptionScrollView,
      counterRow,
    ] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(
        equalTo: descriptionStack.widthAnchor
      ).isActive = true
    }
    let descriptionCard = makeCard(
      containing: descriptionStack
    )

    let emailTitle = NSTextField(labelWithString: "Email for reply")
    emailTitle.font = .systemFont(ofSize: 16, weight: .semibold)
    let emailOptionalLabel = NSTextField(labelWithString: "Optional")
    emailOptionalLabel.font = .systemFont(ofSize: 11, weight: .medium)
    emailOptionalLabel.textColor = .tertiaryLabelColor
    let emailHeader = NSStackView(views: [emailTitle, emailOptionalLabel])
    emailHeader.orientation = .horizontal
    emailHeader.alignment = .centerY
    emailHeader.spacing = 8

    replyEmailField.placeholderString = "you@example.com"
    replyEmailField.setAccessibilityLabel("Email for reply, optional")
    replyEmailField.delegate = self
    replyEmailField.heightAnchor.constraint(equalToConstant: 28)
      .isActive = true
    let emailStack = NSStackView(views: [emailHeader, replyEmailField])
    emailStack.orientation = .vertical
    emailStack.alignment = .leading
    emailStack.spacing = 8
    replyEmailField.translatesAutoresizingMaskIntoConstraints = false
    replyEmailField.widthAnchor.constraint(equalTo: emailStack.widthAnchor)
      .isActive = true
    let emailCard = makeCard(containing: emailStack)

    chooseImageButton.target = self
    chooseImageButton.action = #selector(chooseImage)
    chooseImageButton.image = NSImage(
      systemSymbolName: "photo.on.rectangle.angled",
      accessibilityDescription: nil
    )
    chooseImageButton.imagePosition = .imageLeading

    emptyAttachmentLabel.textColor = .secondaryLabelColor
    emptyAttachmentLabel.alignment = .center

    attachmentPreviewStack.orientation = .horizontal
    attachmentPreviewStack.alignment = .centerY
    attachmentPreviewStack.spacing = 8
    attachmentPreviewStack.edgeInsets = NSEdgeInsets(
      top: 0,
      left: 1,
      bottom: 0,
      right: 1
    )

    attachmentPreviewScrollView.hasHorizontalScroller = true
    attachmentPreviewScrollView.hasVerticalScroller = false
    attachmentPreviewScrollView.autohidesScrollers = true
    attachmentPreviewScrollView.borderType = .noBorder
    attachmentPreviewScrollView.drawsBackground = false
    attachmentPreviewScrollView.documentView = attachmentPreviewStack
    attachmentPreviewScrollView.translatesAutoresizingMaskIntoConstraints = false
    attachmentPreviewScrollView.heightAnchor.constraint(equalToConstant: 90)
      .isActive = true
    attachmentPreviewScrollView.isHidden = true

    let attachmentTitle = NSTextField(
      labelWithString: "Images"
    )
    attachmentTitle.font = .systemFont(
      ofSize: 16,
      weight: .semibold
    )
    let optionalLabel = NSTextField(labelWithString: "Optional")
    optionalLabel.font = .systemFont(ofSize: 11, weight: .medium)
    optionalLabel.textColor = .tertiaryLabelColor
    let titleSpacer = NSView()
    titleSpacer.setContentHuggingPriority(
      .defaultLow,
      for: .horizontal
    )
    let attachmentHeader = NSStackView(
      views: [
        attachmentTitle,
        optionalLabel,
        titleSpacer,
        chooseImageButton,
      ]
    )
    attachmentHeader.orientation = .horizontal
    attachmentHeader.alignment = .centerY
    attachmentHeader.spacing = 8

    let attachmentStack = NSStackView(
      views: [
        attachmentHeader,
        emptyAttachmentLabel,
        attachmentPreviewScrollView,
      ]
    )
    attachmentStack.orientation = .vertical
    attachmentStack.alignment = .leading
    attachmentStack.spacing = 10
    for view in [
      attachmentHeader,
      emptyAttachmentLabel,
      attachmentPreviewScrollView,
    ] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(
        equalTo: attachmentStack.widthAnchor
      ).isActive = true
    }
    let attachmentCard = makeCard(
      containing: attachmentStack
    )

    let privacyText = NSTextField(
      wrappingLabelWithString:
        "Sends your description, app/macOS versions, and any email or images you add. Never include passwords or account details."
    )
    privacyText.textColor = .secondaryLabelColor
    privacyText.maximumNumberOfLines = 3
    let privacyIcon = NSImageView(
      image: NSImage(
        systemSymbolName: "lock.shield.fill",
        accessibilityDescription: "Privacy"
      ) ?? NSImage()
    )
    privacyIcon.contentTintColor = .systemGreen
    privacyIcon.setContentHuggingPriority(
      .required,
      for: .horizontal
    )
    let privacyRow = NSStackView(
      views: [privacyIcon, privacyText]
    )
    privacyRow.orientation = .horizontal
    privacyRow.alignment = .centerY
    privacyRow.spacing = 9

    statusLabel.textColor = .secondaryLabelColor
    statusLabel.maximumNumberOfLines = 2
    statusLabel.setAccessibilityLabel("Bug report status")

    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}"

    submitButton.target = self
    submitButton.action = #selector(submit)
    submitButton.keyEquivalent = "\r"
    submitButton.bezelStyle = .rounded
    submitButton.disabledAlphaValue = 1
    updateSubmitButtonTitle("Submit Report")
    updateSubmitButtonState()

    let buttonSpacer = NSView()
    buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let buttonRow = NSStackView(
      views: [statusLabel, buttonSpacer, cancelButton, submitButton]
    )
    buttonRow.orientation = .horizontal
    buttonRow.alignment = .centerY
    buttonRow.spacing = 10

    let stack = NSStackView(
      views: [
        header,
        descriptionCard,
        emailCard,
        attachmentCard,
        privacyRow,
        buttonRow,
      ]
    )
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    formContentView = stack

    for view in [
      header,
      descriptionCard,
      emailCard,
      attachmentCard,
      privacyRow,
      buttonRow,
    ] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(
        equalTo: stack.widthAnchor
      ).isActive = true
    }
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(
        equalTo: contentView.leadingAnchor,
        constant: 18
      ),
      stack.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor,
        constant: -18
      ),
      stack.topAnchor.constraint(
        equalTo: contentView.topAnchor,
        constant: 16
      ),
      stack.bottomAnchor.constraint(
        lessThanOrEqualTo: contentView.bottomAnchor,
        constant: -16
      ),
    ])

    let successView = makeSuccessView()
    successView.translatesAutoresizingMaskIntoConstraints = false
    successView.isHidden = true
    contentView.addSubview(successView)
    successContentView = successView
    NSLayoutConstraint.activate([
      successView.leadingAnchor.constraint(
        equalTo: contentView.leadingAnchor,
        constant: 18
      ),
      successView.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor,
        constant: -18
      ),
      successView.topAnchor.constraint(
        equalTo: contentView.topAnchor,
        constant: 16
      ),
      successView.bottomAnchor.constraint(
        equalTo: contentView.bottomAnchor,
        constant: -16
      ),
    ])
  }

  private func makeSuccessView() -> NSView {
    let container = NSView()

    let icon = NSImageView(
      image: NSImage(
        systemSymbolName: "checkmark.circle.fill",
        accessibilityDescription: "Report sent"
      ) ?? NSImage()
    )
    icon.contentTintColor = .systemGreen
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 54),
      icon.heightAnchor.constraint(equalToConstant: 54),
    ])

    let title = NSTextField(
      labelWithString: "Report sent. Thank you!"
    )
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    title.alignment = .center

    let closeButton = HoverButton(
      title: "Close",
      target: self,
      action: #selector(cancel)
    )
    closeButton.keyEquivalent = "\u{1b}"

    let anotherReportButton = HoverButton(
      title: "Send Another Report",
      target: self,
      action: #selector(sendAnotherReport)
    )
    anotherReportButton.bezelColor = .systemBlue
    anotherReportButton.attributedTitle = NSAttributedString(
      string: "Send Another Report",
      attributes: [
        .foregroundColor: NSColor.white,
        .font: NSFont.systemFont(
          ofSize: NSFont.systemFontSize,
          weight: .medium
        ),
      ]
    )

    let buttonRow = NSStackView(
      views: [closeButton, anotherReportButton]
    )
    buttonRow.orientation = .horizontal
    buttonRow.alignment = .centerY
    buttonRow.spacing = 10

    let successStack = NSStackView(
      views: [icon, title, buttonRow]
    )
    successStack.orientation = .vertical
    successStack.alignment = .centerX
    successStack.spacing = 18
    successStack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(successStack)
    NSLayoutConstraint.activate([
      successStack.centerXAnchor.constraint(
        equalTo: container.centerXAnchor
      ),
      successStack.centerYAnchor.constraint(
        equalTo: container.centerYAnchor
      ),
      successStack.leadingAnchor.constraint(
        greaterThanOrEqualTo: container.leadingAnchor,
        constant: 20
      ),
      successStack.trailingAnchor.constraint(
        lessThanOrEqualTo: container.trailingAnchor,
        constant: -20
      ),
    ])
    return container
  }

  private func makeCard(containing content: NSView) -> NSView {
    let card = BugReportCardView()
    content.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(
        equalTo: card.leadingAnchor,
        constant: 12
      ),
      content.trailingAnchor.constraint(
        equalTo: card.trailingAnchor,
        constant: -12
      ),
      content.topAnchor.constraint(
        equalTo: card.topAnchor,
        constant: 11
      ),
      content.bottomAnchor.constraint(
        equalTo: card.bottomAnchor,
        constant: -11
      ),
    ])
    return card
  }

  func textDidChange(_ notification: Notification) {
    let count = BugReportContent.descriptionLength(
      descriptionTextView.string
    )
    characterCountLabel.stringValue =
      "\(count) / \(BugReportContent.maximumDescriptionLength)"
    characterCountLabel.textColor =
      count > BugReportContent.maximumDescriptionLength
        ? .systemRed
        : .secondaryLabelColor
    statusLabel.stringValue = ""
    updateSubmitButtonState()
  }

  func controlTextDidChange(_ notification: Notification) {
    let email = replyEmailField.stringValue.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if BugReportContent.isValidOptionalReplyEmail(email) {
      statusLabel.stringValue = ""
    } else {
      showError("Enter a valid email address or leave it blank.")
    }
    updateSubmitButtonState()
  }

  @objc private func chooseImage() {
    let panel = NSOpenPanel()
    panel.title = "Choose Images"
    panel.prompt = "Choose"
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.image]

    guard let window else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK else { return }
      self?.selectImages(at: panel.urls)
    }
  }

  private func selectImages(at urls: [URL]) {
    guard !urls.isEmpty else { return }
    let inputs = urls.map { url in
      BugReportImageInput(
        source: .file(url),
        name: url.lastPathComponent
      )
    }
    attachImages(inputs)
  }

  private func attachImages(_ inputs: [BugReportImageInput]) {
    guard !inputs.isEmpty else { return }
    guard
      attachments.count + inputs.count
        <= BugReportContent.maximumImageCount
    else {
      showError("You can attach up to 5 images.")
      return
    }

    var newAttachments: [BugReportAttachment] = []
    do {
      for input in inputs {
        newAttachments.append(
          try makeAttachment(
            from: input.source,
            name: input.name
          )
        )
      }
      attachments.append(contentsOf: newAttachments)
      updateAttachmentControls()
      showAttachmentFeedback()
    } catch {
      for attachment in newAttachments {
        try? FileManager.default.removeItem(at: attachment.url)
      }
      showError(
        "The image could not be attached. Choose a supported image no larger than 25 MB."
      )
    }
  }

  private func makeAttachment(
    from source: BugReportImageSource,
    name: String
  ) throws -> BugReportAttachment {
    let prepared = try BugReportImageProcessor.prepare(source)
    return BugReportAttachment(
      url: try storeTemporaryJPEG(prepared.jpeg),
      name: name,
      preview: makePreview(from: prepared.image)
    )
  }

  private func makePreview(from image: NSImage) -> NSImage {
    let sourceSize = image.size
    let maximumPreviewDimension: CGFloat = 240
    let scale = min(
      1,
      maximumPreviewDimension
        / max(sourceSize.width, sourceSize.height)
    )
    let targetSize = NSSize(
      width: max(1, floor(sourceSize.width * scale)),
      height: max(1, floor(sourceSize.height * scale))
    )
    let preview = NSImage(size: targetSize)
    preview.lockFocus()
    image.draw(
      in: NSRect(origin: .zero, size: targetSize),
      from: NSRect(origin: .zero, size: sourceSize),
      operation: .copy,
      fraction: 1
    )
    preview.unlockFocus()
    return preview
  }

  private func storeTemporaryJPEG(_ data: Data) throws -> URL {
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "HS-Reconnect-Bug-Report-\(UUID().uuidString).jpg"
      )
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.path
    )
    return destination
  }

  private func updateAttachmentControls() {
    for view in attachmentPreviewStack.arrangedSubviews {
      attachmentPreviewStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for attachment in attachments {
      let preview = BugReportAttachmentPreview(
        attachment: attachment
      )
      preview.onRemove = { [weak self] attachmentID in
        self?.removeAttachment(withID: attachmentID)
      }
      attachmentPreviewStack.addArrangedSubview(preview)
    }

    attachmentPreviewStack.layoutSubtreeIfNeeded()
    let previewWidth = max(
      attachmentPreviewScrollView.contentSize.width,
      attachmentPreviewStack.fittingSize.width
    )
    attachmentPreviewStack.frame = NSRect(
      x: 0,
      y: 0,
      width: previewWidth,
      height: 86
    )

    let count = attachments.count
    emptyAttachmentLabel.isHidden = count > 0
    attachmentPreviewScrollView.isHidden = count == 0
    resizeWindow(showingPreviews: count > 0)
    chooseImageButton.isEnabled =
      !isSubmitting && count < BugReportContent.maximumImageCount
    chooseImageButton.toolTip = count == BugReportContent.maximumImageCount
      ? "Maximum of 5 images attached"
      : "Attach images"
  }

  private func resizeWindow(showingPreviews: Bool) {
    guard let window else { return }
    let targetHeight = showingPreviews
      ? Self.previewWindowHeight
      : Self.compactWindowHeight
    guard abs(window.frame.height - targetHeight) > 0.5 else {
      return
    }
    var frame = window.frame
    frame.origin.y += frame.height - targetHeight
    frame.size.height = targetHeight
    window.setFrame(
      frame,
      display: true,
      animate:
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
  }

  private func removeAttachment(withID id: UUID) {
    guard !isSubmitting,
      let index = attachments.firstIndex(where: { $0.id == id })
    else {
      return
    }
    let removed = attachments.remove(at: index)
    try? FileManager.default.removeItem(at: removed.url)
    updateAttachmentControls()
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.stringValue = attachments.isEmpty
      ? "Image removed."
      : "Image removed — \(attachments.count) remaining."
    NSAccessibility.post(
      element: statusLabel,
      notification: .valueChanged
    )
  }

  private func showAttachmentFeedback() {
    statusLabel.textColor = .systemGreen
    statusLabel.stringValue = attachments.count == 1
      ? "Image attached."
      : "\(attachments.count) images attached."
    NSAccessibility.post(
      element: statusLabel,
      notification: .valueChanged
    )
  }

  @objc private func submit() {
    let bundle = Bundle.main
    do {
      let content = try BugReportContent(
        description: descriptionTextView.string,
        replyEmail: replyEmailField.stringValue,
        appVersion: bundle.object(
          forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Unknown",
        buildNumber: bundle.object(
          forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "Unknown",
        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
      )
      setSubmitting(true)
      submissionTask = Task { [weak self] in
        guard let self else { return }
        do {
          try await client.submit(
            content: content,
            imageURLs: attachments.map(\.url)
          )
          guard !Task.isCancelled else { return }
          await MainActor.run {
            self.setSubmitting(false)
            self.resetForm()
            self.showSuccessState()
          }
        } catch BugReportClientError.notConfigured {
          guard !Task.isCancelled else { return }
          await MainActor.run {
            self.setSubmitting(false)
            self.showError("Bug reporting is not configured yet.")
          }
        } catch {
          guard !Task.isCancelled else { return }
          await MainActor.run {
            self.setSubmitting(false)
            self.showError(
              "The report could not be sent. Check your connection and try again."
            )
          }
        }
      }
    } catch BugReportValidationError.emptyDescription {
      showDescriptionTooShortError()
    } catch BugReportValidationError.descriptionTooShort {
      showDescriptionTooShortError()
    } catch BugReportValidationError.descriptionTooLong {
      showError(
        "Keep the description under \(BugReportContent.maximumDescriptionLength) characters."
      )
    } catch BugReportValidationError.invalidReplyEmail {
      showError("Enter a valid email address or leave it blank.")
    } catch {
      showError("The report could not be prepared. Please try again.")
    }
  }

  @objc private func cancel() {
    close()
  }

  @objc private func sendAnotherReport() {
    resetForm()
    formContentView?.isHidden = false
    successContentView?.isHidden = true
    window?.makeFirstResponder(descriptionTextView)
  }

  func windowWillClose(_ notification: Notification) {
    submissionTask?.cancel()
    submissionTask = nil
    setSubmitting(false)
    resetForm()
    formContentView?.isHidden = false
    successContentView?.isHidden = true
  }

  private func setSubmitting(_ submitting: Bool) {
    isSubmitting = submitting
    updateSubmitButtonState()
    chooseImageButton.isEnabled =
      !submitting
        && attachments.count
          < BugReportContent.maximumImageCount
    for preview in attachmentPreviewStack.arrangedSubviews {
      preview.subviews.compactMap { $0 as? NSButton }
        .forEach { $0.isEnabled = !submitting }
    }
    descriptionTextView.isEditable = !submitting
    replyEmailField.isEnabled = !submitting
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.stringValue = submitting ? "Sending…" : ""
    updateSubmitButtonTitle(
      submitting ? "Sending…" : "Submit Report"
    )
  }

  private func showError(_ message: String) {
    statusLabel.textColor = .systemRed
    statusLabel.stringValue = message
    NSAccessibility.post(
      element: statusLabel,
      notification: .valueChanged
    )
  }

  private func showSuccessState() {
    formContentView?.isHidden = true
    successContentView?.isHidden = false
    window?.makeFirstResponder(nil)
    successSound?.stop()
    successSound?.play()
  }

  private func resetForm() {
    descriptionTextView.string = ""
    replyEmailField.stringValue = ""
    textDidChange(
      Notification(name: NSText.didChangeNotification)
    )
    removeTemporaryAttachments()
    updateAttachmentControls()
    statusLabel.stringValue = ""
  }

  private func showDescriptionTooShortError() {
    showError(
      "Enter at least \(BugReportContent.minimumDescriptionLength) characters."
    )
  }

  private func updateSubmitButtonState() {
    let length = BugReportContent.descriptionLength(
      descriptionTextView.string
    )
    let hasValidLength =
      length >= BugReportContent.minimumDescriptionLength
        && length <= BugReportContent.maximumDescriptionLength
    let hasValidEmail = BugReportContent.isValidOptionalReplyEmail(
      replyEmailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    let canSubmit = !isSubmitting && hasValidLength && hasValidEmail
    submitButton.isEnabled = true
    submitButton.isInteractionAvailable = canSubmit
    submitButton.action = canSubmit ? #selector(submit) : nil
    submitButton.keyEquivalent = canSubmit ? "\r" : ""
    submitButton.setAccessibilityEnabled(canSubmit)
    submitButton.bezelColor = canSubmit ? .systemBlue : .systemGray
    cancelButton.bezelColor = canSubmit ? nil : .systemBlue
    cancelButton.attributedTitle = NSAttributedString(
      string: "Cancel",
      attributes: [
        .foregroundColor:
          canSubmit ? NSColor.labelColor : NSColor.white,
        .font: NSFont.systemFont(
          ofSize: NSFont.systemFontSize,
          weight: .medium
        ),
      ]
    )
  }

  private func removeTemporaryAttachments() {
    for attachment in attachments {
      try? FileManager.default.removeItem(at: attachment.url)
    }
    attachments.removeAll()
  }

  private func updateSubmitButtonTitle(_ title: String) {
    submitButton.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .foregroundColor: NSColor.white,
        .font: NSFont.systemFont(
          ofSize: NSFont.systemFontSize,
          weight: .medium
        ),
      ]
    )
  }
}
