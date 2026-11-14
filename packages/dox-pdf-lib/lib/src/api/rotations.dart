import 'dart:math' as math;

enum RotationTypes { degrees, radians }

/// An angle, in degrees or in radians, like pdf-lib's `Rotation`.
sealed class Rotation {
  const Rotation(this.angle);

  final double angle;

  RotationTypes get type;

  @override
  bool operator ==(Object other) =>
      other is Rotation && other.type == type && other.angle == angle;

  @override
  int get hashCode => Object.hash(type, angle);

  @override
  String toString() => '${type.name}($angle)';
}

class Degrees extends Rotation {
  const Degrees(super.angle);

  @override
  RotationTypes get type => RotationTypes.degrees;
}

class Radians extends Rotation {
  const Radians(super.angle);

  @override
  RotationTypes get type => RotationTypes.radians;
}

Degrees degrees(double degreeAngle) => Degrees(degreeAngle);

Radians radians(double radianAngle) => Radians(radianAngle);

double degreesToRadians(double degree) => degree * math.pi / 180;

double radiansToDegrees(double radian) => radian * 180 / math.pi;

double toRadians(Rotation rotation) => switch (rotation) {
  Radians() => rotation.angle,
  Degrees() => degreesToRadians(rotation.angle),
};

double toDegrees(Rotation rotation) => switch (rotation) {
  Radians() => radiansToDegrees(rotation.angle),
  Degrees() => rotation.angle,
};
