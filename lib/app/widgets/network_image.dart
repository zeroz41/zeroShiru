import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

/// A [CachedNetworkImageProvider] that decodes at the width it is displayed
/// at instead of the source's full resolution.
///
/// AniList covers (~500×700) and banners (~1900×400) decode to megabytes of
/// ARGB each; at full size a screen of rails overflows Flutter's image cache
/// and re-decodes while scrolling. Upscaling stays disabled, so a source
/// already smaller than the target decodes at its native size.
ImageProvider sizedNetworkImage(
  BuildContext context,
  String url, {
  required double logicalWidth,
}) => ResizeImage(
  CachedNetworkImageProvider(url),
  width: (logicalWidth * MediaQuery.devicePixelRatioOf(context)).ceil(),
);
