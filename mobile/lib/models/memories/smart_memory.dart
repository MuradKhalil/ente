import "package:photos/generated/l10n.dart";
import "package:photos/models/base/id.dart";
import "package:photos/models/file/file_type.dart";
import "package:photos/models/memories/memory.dart";
import "package:photos/services/search_service.dart";

enum MemoryType {
  people,
  trips,
  clip,
  time,
  filler,
  onThisDay,
}

MemoryType memoryTypeFromString(String type) {
  switch (type) {
    case "people":
      return MemoryType.people;
    case "trips":
      return MemoryType.trips;
    case "time":
      return MemoryType.time;
    case "filler":
      return MemoryType.filler;
    case "clip":
      return MemoryType.clip;
    case "onThisDay":
      return MemoryType.onThisDay;
    default:
      throw ArgumentError("Invalid memory type: $type");
  }
}

class SmartMemory {
  final List<Memory> memories;
  final MemoryType type;
  String title;
  int firstDateToShow;
  int lastDateToShow;
  late final String id;

  int? firstCreationTime;
  int? lastCreationTime;

  SmartMemory(
    this.memories,
    this.type,
    this.title,
    this.firstDateToShow,
    this.lastDateToShow, {
    String? id,
    this.firstCreationTime,
    this.lastCreationTime,
  }) {
    this.id = id ?? newID(type.name);
  }

  bool get notForShow => firstDateToShow == 0 && lastDateToShow == 0;

  bool isOld() {
    return lastDateToShow < DateTime.now().microsecondsSinceEpoch;
  }

  bool shouldShowNow() {
    final int now = DateTime.now().microsecondsSinceEpoch;
    return now >= firstDateToShow && now <= lastDateToShow;
  }

  String createTitle(S s, String languageCode) {
    throw UnimplementedError("createTitle must be implemented in subclass");
  }

  int averageCreationTime() {
    if (firstCreationTime != null && lastCreationTime != null) {
      return (firstCreationTime! + lastCreationTime!) ~/ 2;
    }
    final List<int> creationTimes = memories
        .where((memory) => memory.file.creationTime != null)
        .map((memory) => memory.file.creationTime!)
        .toList();
    if (creationTimes.length < 2) {
      if (creationTimes.isEmpty) {
        firstCreationTime = 0;
        lastCreationTime = 0;
        return 0;
      }
      return creationTimes.isEmpty ? 0 : creationTimes.first;
    }
    creationTimes.sort();
    firstCreationTime ??= creationTimes.first;
    lastCreationTime ??= creationTimes.last;
    return (firstCreationTime! + lastCreationTime!) ~/ 2;
  }
}

Future<List<SmartMemory>> livePhotosMemory() async {
  final allFiles = await SearchService.instance.getAllFilesForSearch();
  final livePhotos =
      allFiles.where((file) => file.fileType == FileType.livePhoto).toList();
  final videos = allFiles
      .where((file) => file.fileType == FileType.video && file.isRemoteFile)
      .toList();
  return [
    // SmartMemory(
    //   Memory.fromFiles(livePhotos, null),
    //   MemoryType.clip,
    //   "Live Photos",
    //   0,
    //   0,
    //   id: "live_photos_memory",
    // ),
    SmartMemory(
      Memory.fromFiles(videos, null),
      MemoryType.clip,
      "Videos",
      0,
      0,
      id: "videos_memory",
    ),
  ];
}
