import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import '../../models/models.dart';
import '../../theme.dart';
import '../help_tip.dart';
import 'body_kind.dart';
import 'body_tools.dart';
import 'external_open.dart';
import 'hex_view.dart';

/// HTML larger than this is cut before it is drawn; "Open in browser" still
/// gets the whole page.
const htmlPreviewLimit = 1024 * 1024;

/// Renders the response body the way a browser would: HTML pages (as static
/// content), PNG, JPEG, GIF, WebP and BMP images, SVG and PDF files. Other
/// binary data gets a hex view; text and JSON point to the Pretty and Raw
/// tabs.
class ResponsePreview extends StatefulWidget {
  const ResponsePreview({super.key, required this.response, this.request});

  final ResponseData response;

  /// The request that produced [response], used to name saved files.
  final RequestModel? request;

  @override
  State<ResponsePreview> createState() => _ResponsePreviewState();
}

class _ResponsePreviewState extends State<ResponsePreview> {
  late BodyKind _kind;
  Uint8List? _bytes;
  ({int width, int height})? _dims;
  int? _pages;
  String? _html;
  bool _htmlCut = false;
  bool _remoteImages = false;
  final _zoom = TransformationController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ResponsePreview old) {
    super.didUpdateWidget(old);
    if (!identical(old.response, widget.response)) {
      _remoteImages = false;
      _zoom.value = Matrix4.identity();
      _load();
    }
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  /// Works out everything the build needs once per response, so rebuilds
  /// never decode, scan or copy the body again.
  void _load() {
    final res = widget.response;
    final body = res.bodyBytes;
    _kind = detectBodyKind(res.contentType, body);
    _bytes = null;
    _dims = null;
    _pages = null;
    _html = null;
    _htmlCut = false;
    if (_kind.isRaster || _kind == BodyKind.svg) {
      _bytes = body is Uint8List ? body : Uint8List.fromList(body);
    }
    if (_kind.isRaster) _dims = imageDimensions(body, _kind);
    if (_kind == BodyKind.pdf) _pages = pdfPageCount(body);
    if (_kind == BodyKind.html) {
      _htmlCut = body.length > htmlPreviewLimit;
      final shown = _htmlCut ? body.sublist(0, htmlPreviewLimit) : body;
      _html = utf8.decode(shown, allowMalformed: true);
    }
  }

  RequestModel get _request => widget.request ?? RequestModel();

  @override
  Widget build(BuildContext context) => switch (_kind) {
    BodyKind.empty => _note(
      Icons.inbox_outlined,
      'The response has no body.',
      'Nothing to preview.',
    ),
    BodyKind.html => _htmlView(),
    BodyKind.svg => _svgView(),
    BodyKind.pdf => _pdfView(),
    BodyKind.json || BodyKind.text => _textView(),
    BodyKind.binary => _binaryView(),
    _ => _imageView(),
  };

  // --- shared pieces -------------------------------------------------------

  TextStyle get _info => TextStyle(color: Palette.textDim, fontSize: 12.5);

  Widget _fact(String text, String title, String help) => HelpHover(
    help,
    title: title,
    child: Text(text, style: _info),
  );

  Widget _note(IconData icon, String title, String detail, {Widget? actions}) =>
      Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: Palette.border),
              const SizedBox(height: 10),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(color: Palette.textDim, fontSize: 12.5),
              ),
              if (actions != null) ...[const SizedBox(height: 14), actions],
            ],
          ),
        ),
      );

  Widget _bar(List<Widget> children) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
    child: Wrap(
      spacing: 14,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    ),
  );

  Widget _action(
    IconData icon,
    String label,
    VoidCallback onTap, {
    required String title,
    required String help,
    String? example,
    bool primary = false,
  }) {
    final button = primary
        ? FilledButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 16),
            label: Text(label),
          )
        : OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 16),
            label: Text(label),
          );
    return HelpHover(help, title: title, example: example, child: button);
  }

  // --- text and JSON -------------------------------------------------------

  Widget _textView() {
    final tabs = DefaultTabController.maybeOf(context);
    final what = _kind == BodyKind.json ? 'JSON' : 'text';
    return _note(
      Icons.article_outlined,
      'This response is $what, so there is nothing to render.',
      'Pretty shows it laid out for reading and Raw shows it exactly as '
          'received.',
      actions: tabs == null
          ? null
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _action(
                  Icons.data_object,
                  'Open Pretty',
                  () => tabs.animateTo(0),
                  title: 'Pretty view',
                  help: 'Go to the Pretty tab: JSON indented and colour-coded.',
                ),
                _action(
                  Icons.notes,
                  'Open Raw',
                  () => tabs.animateTo(1),
                  title: 'Raw view',
                  help: 'Go to the Raw tab: the body exactly as received.',
                ),
              ],
            ),
    );
  }

  // --- images --------------------------------------------------------------

  Widget _viewer(Widget child) => Container(
    color: Palette.surfaceAlt,
    child: InteractiveViewer(
      transformationController: _zoom,
      minScale: 0.5,
      maxScale: 12,
      clipBehavior: Clip.hardEdge,
      child: Center(child: child),
    ),
  );

  Widget _resetZoom() => HelpHover(
    'Pinch or scroll to zoom the image and drag to move it. This puts it '
    'back to fit the pane.',
    title: 'Reset zoom',
    child: InkWell(
      onTap: () => _zoom.value = Matrix4.identity(),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(Icons.zoom_out_map, size: 18, color: Palette.textDim),
      ),
    ),
  );

  Widget _imageView() {
    final res = widget.response;
    final d = _dims;
    return _Pane(
      header: _bar([
        _fact(
          _kind.label,
          'Image type',
          'The picture format, decided from the Content-Type header or, '
              'when that is missing, from the first bytes of the body.',
        ),
        if (d != null)
          _fact(
            '${d.width} × ${d.height} px',
            'Dimensions',
            'Width and height of the picture in pixels, read from the '
                'file header.',
          ),
        _fact(
          formatByteSize(res.sizeBytes),
          'File size',
          'Size of the image file as received.',
        ),
        _resetZoom(),
      ]),
      body: _viewer(
        Image.memory(
          _bytes!,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              'The ${_kind.label.toLowerCase()} could not be decoded.',
              style: TextStyle(color: Palette.textDim),
            ),
          ),
        ),
      ),
    );
  }

  Widget _svgView() {
    final res = widget.response;
    return _Pane(
      header: _bar([
        _fact(
          _kind.label,
          'Image type',
          'A vector picture. Scripts and links to other files inside it '
              'are ignored. The Raw tab shows its markup.',
        ),
        _fact(
          formatByteSize(res.sizeBytes),
          'File size',
          'Size of the SVG file as received.',
        ),
        _resetZoom(),
      ]),
      body: _viewer(
        SvgPicture.memory(
          _bytes!,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              'The SVG could not be drawn. Raw shows its markup.',
              style: TextStyle(color: Palette.textDim),
            ),
          ),
        ),
      ),
    );
  }

  // --- PDF -----------------------------------------------------------------

  Widget _pdfView() {
    final res = widget.response;
    final pages = _pages;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Palette.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Palette.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.picture_as_pdf_outlined,
                  size: 44,
                  color: Palette.delete,
                ),
                const SizedBox(height: 8),
                const Text(
                  'PDF document',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                HelpHover(
                  'File size, and the number of pages when the file lists '
                  'them in plain text.',
                  title: 'PDF details',
                  example: '12 pages • 240 KB',
                  child: Text(
                    [
                      if (pages != null) '$pages page${pages == 1 ? '' : 's'}',
                      formatByteSize(res.sizeBytes),
                    ].join(' • '),
                    textAlign: TextAlign.center,
                    style: _info,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    _action(
                      Icons.open_in_new,
                      'Open in viewer',
                      () => openBytesExternally(
                        context,
                        name: _pdfName(),
                        bytes: res.bodyBytes,
                        app: 'a PDF viewer',
                      ),
                      title: 'Open in viewer',
                      help:
                          'Writes the PDF to a temporary file and opens it in '
                          'your default PDF app.',
                      primary: true,
                    ),
                    _action(
                      Icons.save_alt,
                      'Save',
                      () => saveResponseBody(context, res, _request),
                      title: 'Save PDF',
                      help: 'Saves the PDF to a file you choose.',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _pdfName() {
    final n = suggestedFileName(widget.response, _request);
    return n.toLowerCase().endsWith('.pdf') ? n : '$n.pdf';
  }

  // --- other binary --------------------------------------------------------

  Widget _binaryView() {
    final res = widget.response;
    final mime = mediaTypeOf(res.contentType);
    return _Pane(
      header: _bar([
        _fact(
          'Binary data',
          'Binary body',
          'This body is not text or a picture the app can draw, so it is '
              'shown as bytes.',
        ),
        if (mime.isNotEmpty)
          _fact(
            mime,
            'Content-Type',
            'The format the server says this body is in.',
          ),
        _fact(
          formatByteSize(res.sizeBytes),
          'Body size',
          'Size of the body as received.',
        ),
      ]),
      body: HexView(bytes: res.bodyBytes),
    );
  }

  // --- HTML ----------------------------------------------------------------

  Uri? get _baseUrl {
    final u = Uri.tryParse(widget.response.finalUrl ?? '');
    return u != null && (u.scheme == 'http' || u.scheme == 'https') ? u : null;
  }

  Widget _htmlView() {
    final res = widget.response;
    return _Pane(
      header: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _bar([
            HelpHover(
              'Pictures from other servers are not fetched unless you turn '
              'this on, because loading them tells that server you opened '
              'the page. Images embedded in the page always show.',
              title: 'Load remote images',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: _remoteImages,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) => setState(() => _remoteImages = v),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      'Load remote images',
                      style: _info,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            _action(
              Icons.open_in_browser,
              'Open in browser',
              _openInBrowser,
              title: 'Open in browser',
              help:
                  'Saves the page to a temporary file and opens it in your '
                  'browser, where its scripts will run. Relative links and '
                  'images point back to the server it came from.',
            ),
            _fact(
              formatByteSize(res.sizeBytes),
              'Page size',
              'Size of the HTML as received.',
            ),
          ]),
          if (_htmlCut)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: Text(
                'Showing the first ${formatByteSize(htmlPreviewLimit)} of the '
                'page. Open in browser shows all of it.',
                style: TextStyle(color: Palette.warning, fontSize: 12),
              ),
            ),
          Divider(height: 1, color: Palette.border),
        ],
      ),
      // A page keeps its own colours, so it is drawn on white like a
      // browser tab whatever the app theme is.
      body: ColoredBox(
        color: Colors.white,
        child: HtmlWidget(
          _html!,
          key: ValueKey(_remoteImages),
          baseUrl: _baseUrl,
          renderMode: RenderMode.listView,
          textStyle: const TextStyle(color: Color(0xFF1F2430), fontSize: 14),
          factoryBuilder: () => _PreviewFactory(_remoteImages),
          onTapUrl: _openLink,
        ),
      ),
    );
  }

  Future<bool> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    // Only web and mail links: a page must not reach file: or app schemes.
    if (uri != null && const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
      try {
        await uriLauncher(uri);
      } catch (_) {}
    }
    return true;
  }

  Future<void> _openInBrowser() {
    final res = widget.response;
    // Latin-1 maps every byte to one character, so the page's own encoding
    // survives while the <base> tag is spliced in.
    final withBase = htmlWithBase(latin1.decode(res.bodyBytes), res.finalUrl);
    return openBytesExternally(
      context,
      name: 'response.html',
      bytes: latin1.encode(withBase),
      app: 'the browser',
    );
  }
}

/// A toolbar over a view that takes the rest of the height. When the pane is
/// too short for both (a phone in landscape, say) the whole thing scrolls, so
/// the toolbar can never push the view out of the layout.
class _Pane extends StatelessWidget {
  const _Pane({required this.header, required this.body});

  final Widget header;
  final Widget body;

  /// Below this height the view would be a sliver; scroll instead.
  static const _minHeight = 260.0;

  /// Height given to the view when the pane scrolls.
  static const _scrolledBody = 200.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      if (c.maxHeight >= _minHeight) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            Expanded(child: body),
          ],
        );
      }
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            SizedBox(height: _scrolledBody, child: body),
          ],
        ),
      );
    },
  );
}

/// Builds HTML without network access: pictures embedded in the page as
/// `data:` URLs always draw; `http(s)` ones only when [allowRemote] is on.
/// Local files and app assets never load.
class _PreviewFactory extends WidgetFactory {
  _PreviewFactory(this.allowRemote);

  final bool allowRemote;

  bool _allowed(String url) =>
      url.startsWith('data:image/') ||
      (allowRemote &&
          (url.startsWith('http://') || url.startsWith('https://')));

  @override
  Widget? buildImageWidget(BuildTree tree, ImageSource src) {
    if (!_allowed(src.url)) {
      return _BlockedImage(label: src.image?.alt ?? src.image?.title);
    }
    return super.buildImageWidget(tree, src);
  }

  @override
  ImageProvider? imageProviderFromAsset(String url) => null;

  @override
  ImageProvider? imageProviderFromFileUri(String url) => null;

  @override
  ImageProvider? imageProviderFromNetwork(String url) =>
      _allowed(url) ? super.imageProviderFromNetwork(url) : null;
}

/// Stands in for a picture that was not loaded.
class _BlockedImage extends StatelessWidget {
  const _BlockedImage({this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF667085);
    const icon = Icon(Icons.image_not_supported_outlined, size: 14, color: ink);
    return LayoutBuilder(
      builder: (context, c) {
        // Tracking pixels are 1x1: draw only what fits.
        final roomy = c.maxWidth >= 100 && c.maxHeight >= 28;
        final text = (label ?? '').trim().isEmpty
            ? 'Image not loaded'
            : label!.trim();
        const style = TextStyle(color: ink, fontSize: 12);
        return DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFD0D5DD)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: roomy
              ? Padding(
                  padding: const EdgeInsets.all(6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      icon,
                      const SizedBox(width: 4),
                      if (c.hasBoundedWidth)
                        Flexible(
                          child: Text(
                            text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: style,
                          ),
                        )
                      else
                        Text(text, maxLines: 1, style: style),
                    ],
                  ),
                )
              : const Center(child: icon),
        );
      },
    );
  }
}
