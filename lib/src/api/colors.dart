enum ColorTypes { grayscale, rgb, cmyk }

/// A color, like pdf-lib's `Color`. Every part is from 0 to 1.
sealed class Color {
  const Color();

  ColorTypes get type;
}

class Grayscale extends Color {
  const Grayscale(this.gray);

  final double gray;

  @override
  ColorTypes get type => ColorTypes.grayscale;

  @override
  bool operator ==(Object other) => other is Grayscale && other.gray == gray;

  @override
  int get hashCode => gray.hashCode;
}

class RGB extends Color {
  const RGB(this.red, this.green, this.blue);

  final double red;
  final double green;
  final double blue;

  @override
  ColorTypes get type => ColorTypes.rgb;

  @override
  bool operator ==(Object other) =>
      other is RGB &&
      other.red == red &&
      other.green == green &&
      other.blue == blue;

  @override
  int get hashCode => Object.hash(red, green, blue);
}

class CMYK extends Color {
  const CMYK(this.cyan, this.magenta, this.yellow, this.key);

  final double cyan;
  final double magenta;
  final double yellow;
  final double key;

  @override
  ColorTypes get type => ColorTypes.cmyk;

  @override
  bool operator ==(Object other) =>
      other is CMYK &&
      other.cyan == cyan &&
      other.magenta == magenta &&
      other.yellow == yellow &&
      other.key == key;

  @override
  int get hashCode => Object.hash(cyan, magenta, yellow, key);
}

void _range(double value, String name) {
  if (value < 0 || value > 1) {
    throw RangeError(
      '`$name` must be at least 0 and at most 1, but was actually $value',
    );
  }
}

Grayscale grayscale(double gray) {
  _range(gray, 'gray');
  return Grayscale(gray);
}

RGB rgb(double red, double green, double blue) {
  _range(red, 'red');
  _range(green, 'green');
  _range(blue, 'blue');
  return RGB(red, green, blue);
}

CMYK cmyk(double cyan, double magenta, double yellow, double key) {
  _range(cyan, 'cyan');
  _range(magenta, 'magenta');
  _range(yellow, 'yellow');
  _range(key, 'key');
  return CMYK(cyan, magenta, yellow, key);
}
