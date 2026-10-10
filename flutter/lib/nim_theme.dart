/// The design tokens, as Dart.
///
/// Colours are flatkit's: frq's own dark palette is a `KitColors`, and the
/// light one is the kit's. `KitSystemTheme` picks between them (or the KDE
/// scheme) and the renderer reads the result with `KitTheme.of`, so nothing
/// below this file names a colour of its own.
///
/// What stays here is what flatkit does not carry: the spacing scale and the
/// type sizes the screens were laid out against.
library;

import 'package:flatkit/flatkit.dart';
import 'package:flutter/widgets.dart';

/// frq's own dark palette, the numbers the app has always painted with,
/// mapped onto flatkit's roles.
const frqDark = KitColors(
  brightness: Brightness.dark,
  background: Color(0xFF202833),
  surface: Color(0xFF2C3440),
  hover: Color(0xFF343C48),
  pressed: Color(0xFF48505A),
  border: Color(0xFF3B4450),
  borderStrong: Color(0xFF55606C),
  text: Color(0xFFCCD1D7),
  textDim: Color(0x99CCD1D7),
  accent: Color(0xFFF4E3CF),
  accentHover: Color(0xFFF8ECDE),
  accentPressed: Color(0xFFE6D2BB),
  onAccent: Color(0xFF000000),
  danger: Color(0xFFFDA1A0),
  dangerHover: Color(0xFFFDB6B5),
  onDanger: Color(0xFF000000),
  success: Color(0xFF92CF9C),
  focus: Color(0xFFF4E3CF),
  shadow: Color(0x66000000),
);

const radiusXs = 2.0;
const radiusS = kitRadius;

const spaceXxxs = 4.0;
const spaceXxs = 8.0;
const spaceXs = 12.0;
const spaceS = 16.0;
const spaceM = 24.0;

/// libcosmic's typography, which was code rather than configuration there and
/// is code here for the same reason.
const textTitle3 = 24.0; // :title
const textTitle4 = 20.0; // :title-2
const textBody = 14.0; // :label
const textCaption = 12.0; // :dim-label, :status, :spinner
