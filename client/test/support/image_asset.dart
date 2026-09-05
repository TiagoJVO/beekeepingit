import 'package:flutter/material.dart';

/// The bundled asset an [Image] actually draws.
///
/// Shared by the two files that assert on the brand mark
/// (`theming/brand_widgets_test.dart`, `features/auth/login_screen_test.dart`)
/// because the answer is not simply `image.image as AssetImage`: passing
/// `cacheWidth`/`cacheHeight` — which `BrandMark` does, to avoid decoding the
/// 512² app-icon artwork at full size for a 96dp mark — makes Flutter wrap the
/// provider in a [ResizeImage]. Unwrapping it here keeps that decode decision
/// free to change without rewriting every assertion about *which* image
/// renders.
String assetNameOf(Image image) {
  final provider = image.image;
  final asset = provider is ResizeImage ? provider.imageProvider : provider;
  return (asset as AssetImage).assetName;
}
