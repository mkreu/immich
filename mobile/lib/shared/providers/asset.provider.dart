import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/hive_box.dart';
import 'package:immich_mobile/shared/models/store.dart';
import 'package:immich_mobile/shared/services/asset.service.dart';
import 'package:immich_mobile/shared/services/asset_cache.service.dart';
import 'package:immich_mobile/modules/home/ui/asset_grid/asset_grid_data_structure.dart';
import 'package:immich_mobile/modules/settings/providers/app_settings.provider.dart';
import 'package:immich_mobile/modules/settings/services/app_settings.service.dart';
import 'package:immich_mobile/shared/models/asset.dart';
import 'package:immich_mobile/shared/services/device_info.service.dart';
import 'package:collection/collection.dart';
import 'package:immich_mobile/utils/tuple.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:photo_manager/photo_manager.dart';

class AssetsState {
  final List<Asset> allAssets;
  final RenderList? renderList;

  AssetsState(this.allAssets, {this.renderList});

  Future<AssetsState> withRenderDataStructure(
    AssetGridLayoutParameters layout,
  ) async {
    return AssetsState(
      allAssets,
      renderList: await RenderList.fromAssets(
        allAssets,
        layout,
      ),
    );
  }

  AssetsState withAdditionalAssets(List<Asset> toAdd) {
    return AssetsState([...allAssets, ...toAdd]);
  }

  static AssetsState fromAssetList(List<Asset> assets) {
    return AssetsState(assets);
  }

  static AssetsState empty() {
    return AssetsState([]);
  }
}

class _CombineAssetsComputeParameters {
  final Iterable<Asset> local;
  final Iterable<Asset> remote;
  final String deviceId;

  _CombineAssetsComputeParameters(this.local, this.remote, this.deviceId);
}

class AssetNotifier extends StateNotifier<AssetsState> {
  final AssetService _assetService;
  final AssetCacheService _assetCacheService;
  final AppSettingsService _settingsService;
  final log = Logger('AssetNotifier');
  final DeviceInfoService _deviceInfoService = DeviceInfoService();
  bool _getAllAssetInProgress = false;
  bool _deleteInProgress = false;

  AssetNotifier(
    this._assetService,
    this._assetCacheService,
    this._settingsService,
  ) : super(AssetsState.fromAssetList([]));

  Future<void> _updateAssetsState(
    List<Asset> newAssetList, {
    bool cache = true,
  }) async {
    if (cache) {
      _assetCacheService.put(newAssetList);
    }

    final layout = AssetGridLayoutParameters(
      _settingsService.getSetting(AppSettingsEnum.tilesPerRow),
      _settingsService.getSetting(AppSettingsEnum.dynamicLayout),
      GroupAssetsBy.values[_settingsService.getSetting(AppSettingsEnum.groupAssetsBy)],
    );

    state = await AssetsState.fromAssetList(newAssetList)
        .withRenderDataStructure(layout);
  }

  // Just a little helper to trigger a rebuild of the state object
  Future<void> rebuildAssetGridDataStructure() async {
    await _updateAssetsState(state.allAssets, cache: false);
  }

  getAllAsset() async {
    if (_getAllAssetInProgress || _deleteInProgress) {
      // guard against multiple calls to this method while it's still working
      return;
    }
    final stopwatch = Stopwatch();
    try {
      _getAllAssetInProgress = true;
      bool isCacheValid = await _assetCacheService.isValid();
      stopwatch.start();
      if (isCacheValid && state.allAssets.isEmpty) {
        final List<Asset>? cachedData = await _assetCacheService.get();
        if (cachedData == null) {
          isCacheValid = false;
          log.warning("Cached asset data is invalid, fetching new data");
        } else {
          await _updateAssetsState(cachedData, cache: false);
          log.info(
            "Reading assets ${state.allAssets.length} from cache: ${stopwatch.elapsedMilliseconds}ms",
          );
        }
        stopwatch.reset();
      }
      final localTask = _assetService.getLocalAssets(urgent: !isCacheValid);
      final remoteTask = _assetService.getRemoteAssets(
        etag: isCacheValid ? Store.get(StoreKey.assetETag) : null,
      );

      int remoteBegin = state.allAssets.indexWhere((a) => a.isRemote);
      remoteBegin = remoteBegin == -1 ? state.allAssets.length : remoteBegin;

      final List<Asset> currentLocal = state.allAssets.slice(0, remoteBegin);

      final Pair<List<Asset>?, String?> remoteResult = await remoteTask;
      List<Asset>? newRemote = remoteResult.first;
      List<Asset>? newLocal = await localTask;
      log.info("Load assets: ${stopwatch.elapsedMilliseconds}ms");
      stopwatch.reset();
      if (newRemote == null &&
          (newLocal == null || currentLocal.equals(newLocal))) {
        log.info("state is already up-to-date");
        return;
      }
      newRemote ??= state.allAssets.slice(remoteBegin);
      newLocal ??= [];

      final combinedAssets = await _combineLocalAndRemoteAssets(
        local: newLocal,
        remote: newRemote,
      );
      await _updateAssetsState(combinedAssets);

      log.info("Combining assets: ${stopwatch.elapsedMilliseconds}ms");

      Store.put(StoreKey.assetETag, remoteResult.second);
    } finally {
      _getAllAssetInProgress = false;
    }
  }

  static Future<List<Asset>> _computeCombine(
    _CombineAssetsComputeParameters data,
  ) async {
    var local = data.local;
    var remote = data.remote;
    final deviceId = data.deviceId;

    final List<Asset> assets = [];
    if (remote.isNotEmpty && local.isNotEmpty) {
      final Set<String> existingIds = remote
          .where((e) => e.deviceId == deviceId)
          .map((e) => e.deviceAssetId)
          .toSet();
      local = local.where((e) => !existingIds.contains(e.id));
    }
    assets.addAll(local);
    // the order (first all local, then remote assets) is important!
    assets.addAll(remote);
    return assets;
  }

  Future<List<Asset>> _combineLocalAndRemoteAssets({
    required Iterable<Asset> local,
    required List<Asset> remote,
  }) async {
    final String deviceId = Hive.box(userInfoBox).get(deviceIdKey);
    return await compute(
      _computeCombine,
      _CombineAssetsComputeParameters(local, remote, deviceId),
    );
  }

  clearAllAsset() {
    _updateAssetsState([]);
  }

  void onNewAssetUploaded(Asset newAsset) {
    final int i = state.allAssets.indexWhere(
      (a) =>
          a.isRemote ||
          (a.id == newAsset.deviceAssetId && a.deviceId == newAsset.deviceId),
    );

    if (i == -1 || state.allAssets[i].deviceAssetId != newAsset.deviceAssetId) {
      _updateAssetsState([...state.allAssets, newAsset]);
    } else {
      // order is important to keep all local-only assets at the beginning!
      _updateAssetsState([
        ...state.allAssets.slice(0, i),
        ...state.allAssets.slice(i + 1),
        newAsset,
      ]);
      // TODO here is a place to unify local/remote assets by replacing the
      // local-only asset in the state with a local&remote asset
    }
  }

  deleteAssets(Set<Asset> deleteAssets) async {
    _deleteInProgress = true;
    try {
      final localDeleted = await _deleteLocalAssets(deleteAssets);
      final remoteDeleted = await _deleteRemoteAssets(deleteAssets);
      final Set<String> deleted = HashSet();
      deleted.addAll(localDeleted);
      deleted.addAll(remoteDeleted);
      if (deleted.isNotEmpty) {
        _updateAssetsState(
          state.allAssets.where((a) => !deleted.contains(a.id)).toList(),
        );
      }
    } finally {
      _deleteInProgress = false;
    }
  }

  Future<List<String>> _deleteLocalAssets(Set<Asset> assetsToDelete) async {
    var deviceInfo = await _deviceInfoService.getDeviceInfo();
    var deviceId = deviceInfo["deviceId"];
    final List<String> local = [];
    // Delete asset from device
    for (final Asset asset in assetsToDelete) {
      if (asset.isLocal) {
        local.add(asset.localId!);
      } else if (asset.deviceId == deviceId) {
        // Delete asset on device if it is still present
        var localAsset = await AssetEntity.fromId(asset.deviceAssetId);
        if (localAsset != null) {
          local.add(localAsset.id);
        }
      }
    }
    if (local.isNotEmpty) {
      try {
        return await PhotoManager.editor.deleteWithIds(local);
      } catch (e, stack) {
        log.severe("Failed to delete asset from device", e, stack);
      }
    }
    return [];
  }

  Future<Iterable<String>> _deleteRemoteAssets(
    Set<Asset> assetsToDelete,
  ) async {
    final Iterable<Asset> remote = assetsToDelete.where((e) => e.isRemote);
    final List<DeleteAssetResponseDto> deleteAssetResult =
        await _assetService.deleteAssets(remote) ?? [];
    return deleteAssetResult
        .where((a) => a.status == DeleteAssetStatus.SUCCESS)
        .map((a) => a.id);
  }

  Future<bool> toggleFavorite(Asset asset, bool status) async {
    final newAsset = await _assetService.changeFavoriteStatus(asset, status);

    if (newAsset == null) {
      log.severe("Change favorite status failed for asset ${asset.id}");
      return asset.isFavorite;
    }

    final index = state.allAssets.indexWhere((a) => asset.id == a.id);
    if (index > 0) {
      state.allAssets[index] = newAsset;
      _updateAssetsState(state.allAssets);
    }

    return newAsset.isFavorite;
  }
}

final assetProvider = StateNotifierProvider<AssetNotifier, AssetsState>((ref) {
  return AssetNotifier(
    ref.watch(assetServiceProvider),
    ref.watch(assetCacheServiceProvider),
    ref.watch(appSettingsServiceProvider),
  );
});

final assetGroupByMonthYearProvider = StateProvider((ref) {
  // TODO: remove `where` once temporary workaround is no longer needed (to only
  // allow remote assets to be added to album). Keep `toList()` as to NOT sort
  // the original list/state
  final assets =
      ref.watch(assetProvider).allAssets.where((e) => e.isRemote).toList();

  assets.sortByCompare<DateTime>(
    (e) => e.createdAt,
    (a, b) => b.compareTo(a),
  );

  return assets.groupListsBy(
    (element) => DateFormat('MMMM, y').format(element.createdAt.toLocal()),
  );
});
