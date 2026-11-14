import '../raw_props.dart';
import '../text/text_plugin.dart';

/// The `select` schema type. In the PDF it is a `text` schema: the
/// `options` list only matters in the pdfme designer.
class SelectDrawer implements RawDrawer {
  const SelectDrawer();

  @override
  String get type => 'select';

  @override
  Future<void> draw(RawProps props) => const TextDrawer().draw(props);
}
