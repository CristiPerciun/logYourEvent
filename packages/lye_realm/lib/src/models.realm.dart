// dart format width=80
// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// RealmObjectGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: type=lint
class LyeEventRow extends _LyeEventRow
    with RealmEntity, RealmObjectBase, RealmObject {
  LyeEventRow(
    String eventId,
    String streamId,
    int seq,
    int occurredAtMicros,
    bool shipped,
    String rowHash,
    String rowJson, {
    String? shippedAt,
  }) {
    RealmObjectBase.set(this, 'eventId', eventId);
    RealmObjectBase.set(this, 'streamId', streamId);
    RealmObjectBase.set(this, 'seq', seq);
    RealmObjectBase.set(this, 'occurredAtMicros', occurredAtMicros);
    RealmObjectBase.set(this, 'shipped', shipped);
    RealmObjectBase.set(this, 'shippedAt', shippedAt);
    RealmObjectBase.set(this, 'rowHash', rowHash);
    RealmObjectBase.set(this, 'rowJson', rowJson);
  }

  LyeEventRow._();

  @override
  String get eventId => RealmObjectBase.get<String>(this, 'eventId') as String;
  @override
  set eventId(String value) => RealmObjectBase.set(this, 'eventId', value);

  @override
  String get streamId =>
      RealmObjectBase.get<String>(this, 'streamId') as String;
  @override
  set streamId(String value) => RealmObjectBase.set(this, 'streamId', value);

  @override
  int get seq => RealmObjectBase.get<int>(this, 'seq') as int;
  @override
  set seq(int value) => RealmObjectBase.set(this, 'seq', value);

  @override
  int get occurredAtMicros =>
      RealmObjectBase.get<int>(this, 'occurredAtMicros') as int;
  @override
  set occurredAtMicros(int value) =>
      RealmObjectBase.set(this, 'occurredAtMicros', value);

  @override
  bool get shipped => RealmObjectBase.get<bool>(this, 'shipped') as bool;
  @override
  set shipped(bool value) => RealmObjectBase.set(this, 'shipped', value);

  @override
  String? get shippedAt =>
      RealmObjectBase.get<String>(this, 'shippedAt') as String?;
  @override
  set shippedAt(String? value) => RealmObjectBase.set(this, 'shippedAt', value);

  @override
  String get rowHash => RealmObjectBase.get<String>(this, 'rowHash') as String;
  @override
  set rowHash(String value) => RealmObjectBase.set(this, 'rowHash', value);

  @override
  String get rowJson => RealmObjectBase.get<String>(this, 'rowJson') as String;
  @override
  set rowJson(String value) => RealmObjectBase.set(this, 'rowJson', value);

  @override
  Stream<RealmObjectChanges<LyeEventRow>> get changes =>
      RealmObjectBase.getChanges<LyeEventRow>(this);

  @override
  Stream<RealmObjectChanges<LyeEventRow>> changesFor([
    List<String>? keyPaths,
  ]) => RealmObjectBase.getChangesFor<LyeEventRow>(this, keyPaths);

  @override
  LyeEventRow freeze() => RealmObjectBase.freezeObject<LyeEventRow>(this);

  EJsonValue toEJson() {
    return <String, dynamic>{
      'eventId': eventId.toEJson(),
      'streamId': streamId.toEJson(),
      'seq': seq.toEJson(),
      'occurredAtMicros': occurredAtMicros.toEJson(),
      'shipped': shipped.toEJson(),
      'shippedAt': shippedAt.toEJson(),
      'rowHash': rowHash.toEJson(),
      'rowJson': rowJson.toEJson(),
    };
  }

  static EJsonValue _toEJson(LyeEventRow value) => value.toEJson();
  static LyeEventRow _fromEJson(EJsonValue ejson) {
    if (ejson is! Map<String, dynamic>) return raiseInvalidEJson(ejson);
    return switch (ejson) {
      {
        'eventId': EJsonValue eventId,
        'streamId': EJsonValue streamId,
        'seq': EJsonValue seq,
        'occurredAtMicros': EJsonValue occurredAtMicros,
        'shipped': EJsonValue shipped,
        'rowHash': EJsonValue rowHash,
        'rowJson': EJsonValue rowJson,
      } =>
        LyeEventRow(
          fromEJson(eventId),
          fromEJson(streamId),
          fromEJson(seq),
          fromEJson(occurredAtMicros),
          fromEJson(shipped),
          fromEJson(rowHash),
          fromEJson(rowJson),
          shippedAt: fromEJson(ejson['shippedAt']),
        ),
      _ => raiseInvalidEJson(ejson),
    };
  }

  static final schema = () {
    RealmObjectBase.registerFactory(LyeEventRow._);
    register(_toEJson, _fromEJson);
    return const SchemaObject(
      ObjectType.realmObject,
      LyeEventRow,
      'LyeEventRow',
      [
        SchemaProperty('eventId', RealmPropertyType.string, primaryKey: true),
        SchemaProperty(
          'streamId',
          RealmPropertyType.string,
          indexType: RealmIndexType.regular,
        ),
        SchemaProperty('seq', RealmPropertyType.int),
        SchemaProperty(
          'occurredAtMicros',
          RealmPropertyType.int,
          indexType: RealmIndexType.regular,
        ),
        SchemaProperty(
          'shipped',
          RealmPropertyType.bool,
          indexType: RealmIndexType.regular,
        ),
        SchemaProperty('shippedAt', RealmPropertyType.string, optional: true),
        SchemaProperty('rowHash', RealmPropertyType.string),
        SchemaProperty('rowJson', RealmPropertyType.string),
      ],
    );
  }();

  @override
  SchemaObject get objectSchema => RealmObjectBase.getSchema(this) ?? schema;
}

class LyeChainHeadRow extends _LyeChainHeadRow
    with RealmEntity, RealmObjectBase, RealmObject {
  LyeChainHeadRow(
    String streamId,
    String nodePrefix,
    int seq,
    String headHash,
    String updatedAt,
  ) {
    RealmObjectBase.set(this, 'streamId', streamId);
    RealmObjectBase.set(this, 'nodePrefix', nodePrefix);
    RealmObjectBase.set(this, 'seq', seq);
    RealmObjectBase.set(this, 'headHash', headHash);
    RealmObjectBase.set(this, 'updatedAt', updatedAt);
  }

  LyeChainHeadRow._();

  @override
  String get streamId =>
      RealmObjectBase.get<String>(this, 'streamId') as String;
  @override
  set streamId(String value) => RealmObjectBase.set(this, 'streamId', value);

  @override
  String get nodePrefix =>
      RealmObjectBase.get<String>(this, 'nodePrefix') as String;
  @override
  set nodePrefix(String value) =>
      RealmObjectBase.set(this, 'nodePrefix', value);

  @override
  int get seq => RealmObjectBase.get<int>(this, 'seq') as int;
  @override
  set seq(int value) => RealmObjectBase.set(this, 'seq', value);

  @override
  String get headHash =>
      RealmObjectBase.get<String>(this, 'headHash') as String;
  @override
  set headHash(String value) => RealmObjectBase.set(this, 'headHash', value);

  @override
  String get updatedAt =>
      RealmObjectBase.get<String>(this, 'updatedAt') as String;
  @override
  set updatedAt(String value) => RealmObjectBase.set(this, 'updatedAt', value);

  @override
  Stream<RealmObjectChanges<LyeChainHeadRow>> get changes =>
      RealmObjectBase.getChanges<LyeChainHeadRow>(this);

  @override
  Stream<RealmObjectChanges<LyeChainHeadRow>> changesFor([
    List<String>? keyPaths,
  ]) => RealmObjectBase.getChangesFor<LyeChainHeadRow>(this, keyPaths);

  @override
  LyeChainHeadRow freeze() =>
      RealmObjectBase.freezeObject<LyeChainHeadRow>(this);

  EJsonValue toEJson() {
    return <String, dynamic>{
      'streamId': streamId.toEJson(),
      'nodePrefix': nodePrefix.toEJson(),
      'seq': seq.toEJson(),
      'headHash': headHash.toEJson(),
      'updatedAt': updatedAt.toEJson(),
    };
  }

  static EJsonValue _toEJson(LyeChainHeadRow value) => value.toEJson();
  static LyeChainHeadRow _fromEJson(EJsonValue ejson) {
    if (ejson is! Map<String, dynamic>) return raiseInvalidEJson(ejson);
    return switch (ejson) {
      {
        'streamId': EJsonValue streamId,
        'nodePrefix': EJsonValue nodePrefix,
        'seq': EJsonValue seq,
        'headHash': EJsonValue headHash,
        'updatedAt': EJsonValue updatedAt,
      } =>
        LyeChainHeadRow(
          fromEJson(streamId),
          fromEJson(nodePrefix),
          fromEJson(seq),
          fromEJson(headHash),
          fromEJson(updatedAt),
        ),
      _ => raiseInvalidEJson(ejson),
    };
  }

  static final schema = () {
    RealmObjectBase.registerFactory(LyeChainHeadRow._);
    register(_toEJson, _fromEJson);
    return const SchemaObject(
      ObjectType.realmObject,
      LyeChainHeadRow,
      'LyeChainHeadRow',
      [
        SchemaProperty('streamId', RealmPropertyType.string, primaryKey: true),
        SchemaProperty(
          'nodePrefix',
          RealmPropertyType.string,
          indexType: RealmIndexType.regular,
        ),
        SchemaProperty('seq', RealmPropertyType.int),
        SchemaProperty('headHash', RealmPropertyType.string),
        SchemaProperty('updatedAt', RealmPropertyType.string),
      ],
    );
  }();

  @override
  SchemaObject get objectSchema => RealmObjectBase.getSchema(this) ?? schema;
}
