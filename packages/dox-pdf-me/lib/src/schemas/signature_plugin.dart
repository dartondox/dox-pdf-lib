import '../plugin.dart';
import 'image_plugin.dart';

/// The `signature` schema type. In the PDF it is an `image` schema: the
/// value is the PNG data URL of the signature. The drawing pad only
/// matters in the pdfme designer.
class SignaturePlugin extends SchemaPlugin {
  const SignaturePlugin();

  @override
  String get type => 'signature';

  @override
  Future<void> pdf(RenderProps props) => const ImagePlugin().pdf(props);
}
