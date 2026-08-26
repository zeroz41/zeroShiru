import '../models/catalog.dart';
import '../models/media.dart';

/// Public anime catalogue used by Home, Search, and details. Tracking writes
/// remain on TrackingRepository; browsing never requires a signed-in user.
abstract interface class CatalogRepository {
  Future<MediaPage> browse(MediaBrowseQuery query);
  Future<Media?> mediaById(int id);
}
