import '../raw_props.dart';
import 'image_plugin.dart';

/// The `signature` schema type. In the PDF it is an `image` schema: the
/// value is the PNG data URL of the signature. The drawing pad only
/// matters in the pdfme designer.
class SignatureDrawer implements RawDrawer {
  const SignatureDrawer();

  @override
  String get type => 'signature';

  @override
  Future<void> draw(RawProps props) => const ImageDrawer().draw(props);
}
