// ignore_for_file: constant_identifier_names

/// Page sizes in PDF points (`[width, height]`), the same as pdf-lib's
/// `PageSizes`. `4A0` and `2A0` are `$4A0` and `$2A0`, because a Dart name
/// can not start with a digit.
abstract final class PageSizes {
  static const List<double> $4A0 = <double>[4767.87, 6740.79];
  static const List<double> $2A0 = <double>[3370.39, 4767.87];
  static const List<double> A0 = <double>[2383.94, 3370.39];
  static const List<double> A1 = <double>[1683.78, 2383.94];
  static const List<double> A2 = <double>[1190.55, 1683.78];
  static const List<double> A3 = <double>[841.89, 1190.55];
  static const List<double> A4 = <double>[595.28, 841.89];
  static const List<double> A5 = <double>[419.53, 595.28];
  static const List<double> A6 = <double>[297.64, 419.53];
  static const List<double> A7 = <double>[209.76, 297.64];
  static const List<double> A8 = <double>[147.4, 209.76];
  static const List<double> A9 = <double>[104.88, 147.4];
  static const List<double> A10 = <double>[73.7, 104.88];
  static const List<double> B0 = <double>[2834.65, 4008.19];
  static const List<double> B1 = <double>[2004.09, 2834.65];
  static const List<double> B2 = <double>[1417.32, 2004.09];
  static const List<double> B3 = <double>[1000.63, 1417.32];
  static const List<double> B4 = <double>[708.66, 1000.63];
  static const List<double> B5 = <double>[498.9, 708.66];
  static const List<double> B6 = <double>[354.33, 498.9];
  static const List<double> B7 = <double>[249.45, 354.33];
  static const List<double> B8 = <double>[175.75, 249.45];
  static const List<double> B9 = <double>[124.72, 175.75];
  static const List<double> B10 = <double>[87.87, 124.72];
  static const List<double> C0 = <double>[2599.37, 3676.54];
  static const List<double> C1 = <double>[1836.85, 2599.37];
  static const List<double> C2 = <double>[1298.27, 1836.85];
  static const List<double> C3 = <double>[918.43, 1298.27];
  static const List<double> C4 = <double>[649.13, 918.43];
  static const List<double> C5 = <double>[459.21, 649.13];
  static const List<double> C6 = <double>[323.15, 459.21];
  static const List<double> C7 = <double>[229.61, 323.15];
  static const List<double> C8 = <double>[161.57, 229.61];
  static const List<double> C9 = <double>[113.39, 161.57];
  static const List<double> C10 = <double>[79.37, 113.39];
  static const List<double> RA0 = <double>[2437.8, 3458.27];
  static const List<double> RA1 = <double>[1729.13, 2437.8];
  static const List<double> RA2 = <double>[1218.9, 1729.13];
  static const List<double> RA3 = <double>[864.57, 1218.9];
  static const List<double> RA4 = <double>[609.45, 864.57];
  static const List<double> SRA0 = <double>[2551.18, 3628.35];
  static const List<double> SRA1 = <double>[1814.17, 2551.18];
  static const List<double> SRA2 = <double>[1275.59, 1814.17];
  static const List<double> SRA3 = <double>[907.09, 1275.59];
  static const List<double> SRA4 = <double>[637.8, 907.09];
  static const List<double> Executive = <double>[521.86, 756.0];
  static const List<double> Folio = <double>[612.0, 936.0];
  static const List<double> Legal = <double>[612.0, 1008.0];
  static const List<double> Letter = <double>[612.0, 792.0];
  static const List<double> Tabloid = <double>[792.0, 1224.0];
}
