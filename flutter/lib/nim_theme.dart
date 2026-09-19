/// The design tokens, as Dart.
///
/// The same numbers `flutter/src/frq/theme/tokens.cljd` carries, in the
/// language the renderer is written in. Duplicated rather than imported
/// because that file is ClojureDart and this is the half that is leaving it;
/// when the ClojureDart app goes, so does the other copy.
library;

import 'package:flutter/material.dart';

const accent = Color(0xFFF4E3CF);
const onAccent = Color(0xFF000000);
const bg = Color(0xFF202833);
const onBg = Color(0xFFCCD1D7);
const component = Color(0xFF343C48);
const componentHover = Color(0xFF48505A);
const divider = Color(0x33CCD1D7);
const card = Color(0xFF2C3440);
const cardComponent = Color(0xFF3B4450);
const onCard = Color(0xFFFFFFFF);
const destructive = Color(0xFFFDA1A0);
const onDestructive = Color(0xFF000000);
const success = Color(0xFF92CF9C);

/// `dim` is not a token of its own in the Clojure either — it is `onBg` at
/// the opacity a caption wants, and naming it here keeps that one decision in
/// one place.
const dim = Color(0x99CCD1D7);

const radiusXs = 2.0;
const radiusS = 8.0;
const radiusM = 8.0;

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
