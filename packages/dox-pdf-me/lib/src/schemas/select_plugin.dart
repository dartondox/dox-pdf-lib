import '../plugin.dart';
import '../text/text_plugin.dart';

/// The `select` schema type. In the PDF it is a `text` schema: the
/// `options` list only matters in the pdfme designer.
class SelectPlugin extends SchemaPlugin {
  const SelectPlugin();

  @override
  String get type => 'select';

  @override
  Future<void> pdf(RenderProps props) => const TextPlugin().pdf(props);
}
