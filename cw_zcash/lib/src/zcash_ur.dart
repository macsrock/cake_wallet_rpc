// Keystone-compatible UR envelopes for Zcash airgapped signing, per
// keystone-sdk-rust's ur-registry:
//
//   zcash-accounts (tag 49201):
//     {1: bstr seed_fingerprint, 2: [+ #6.49203(zcash-unified-full-viewing-key)]}
//   zcash-unified-full-viewing-key (tag 49203):
//     {1: text ufvk, 2: uint index, ?3: text name}
//   zcash-pczt (tag 49204):
//     {1: bstr data}
//
// This is the hot-wallet counterpart of the encoder in Cupcake; the two must
// stay byte-compatible, and both must interoperate with a Keystone device.
// The payloads are tiny integer-keyed CBOR maps, so this carries its own
// codec rather than taking a CBOR dependency.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ur/ur.dart';
import 'package:ur/ur_decoder.dart';

const String zcashAccountsUrType = "zcash-accounts";
const String zcashPcztUrType = "zcash-pczt";
const int zcashUfvkCborTag = 49203;

/// A Zcash account exported by an airgapped signer for watch-only tracking.
class ZcashAccountsPayload {
  ZcashAccountsPayload({
    required this.seedFingerprint,
    required this.ufvk,
    required this.accountIndex,
    this.name,
  });

  final Uint8List seedFingerprint;
  final String ufvk;
  final int accountIndex;
  final String? name;
}

class _CborWriter {
  final BytesBuilder _out = BytesBuilder();

  Uint8List take() => _out.takeBytes();

  void _head(final int major, final int value) {
    if (value < 24) {
      _out.addByte((major << 5) | value);
    } else if (value <= 0xff) {
      _out.addByte((major << 5) | 24);
      _out.addByte(value);
    } else if (value <= 0xffff) {
      _out.addByte((major << 5) | 25);
      _out.add([(value >> 8) & 0xff, value & 0xff]);
    } else {
      _out.addByte((major << 5) | 26);
      _out.add([
        (value >> 24) & 0xff,
        (value >> 16) & 0xff,
        (value >> 8) & 0xff,
        value & 0xff,
      ]);
    }
  }

  void uint(final int value) => _head(0, value);

  void bytes(final Uint8List value) {
    _head(2, value.length);
    _out.add(value);
  }

  void text(final String value) {
    final encoded = utf8.encode(value);
    _head(3, encoded.length);
    _out.add(encoded);
  }

  void map(final int length) => _head(5, length);
}

class _CborReader {
  _CborReader(this._data);
  final Uint8List _data;
  int _pos = 0;

  (int, int) _head() {
    final initial = _data[_pos++];
    final major = initial >> 5;
    final additional = initial & 0x1f;
    if (additional < 24) return (major, additional);
    if (additional == 24) return (major, _data[_pos++]);
    if (additional == 25) {
      final v = (_data[_pos] << 8) | _data[_pos + 1];
      _pos += 2;
      return (major, v);
    }
    if (additional == 26) {
      final v = (_data[_pos] << 24) |
          (_data[_pos + 1] << 16) |
          (_data[_pos + 2] << 8) |
          _data[_pos + 3];
      _pos += 4;
      return (major, v);
    }
    throw Exception("unsupported CBOR additional info $additional");
  }

  int mapHeader() {
    final (major, value) = _head();
    if (major != 5) throw Exception("expected CBOR map, got major $major");
    return value;
  }

  int arrayHeader() {
    final (major, value) = _head();
    if (major != 4) throw Exception("expected CBOR array, got major $major");
    return value;
  }

  int uint() {
    final (major, value) = _head();
    if (major != 0) throw Exception("expected CBOR uint, got major $major");
    return value;
  }

  Uint8List bytes() {
    final (major, value) = _head();
    if (major != 2) throw Exception("expected CBOR bytes, got major $major");
    final out = Uint8List.sublistView(_data, _pos, _pos + value);
    _pos += value;
    return out;
  }

  String text() {
    final (major, value) = _head();
    if (major != 3) throw Exception("expected CBOR text, got major $major");
    final out = utf8.decode(Uint8List.sublistView(_data, _pos, _pos + value));
    _pos += value;
    return out;
  }

  /// Consumes a tag head and returns the tag number.
  int tag() {
    final (major, value) = _head();
    if (major != 6) throw Exception("expected CBOR tag, got major $major");
    return value;
  }

  void skip() {
    final (major, value) = _head();
    switch (major) {
      case 0:
      case 1:
        return;
      case 2:
      case 3:
        _pos += value;
        return;
      case 4:
        for (var i = 0; i < value; i++) {
          skip();
        }
        return;
      case 5:
        for (var i = 0; i < 2 * value; i++) {
          skip();
        }
        return;
      case 6:
        skip();
        return;
      default:
        throw Exception("unsupported CBOR major type $major");
    }
  }
}

/// Encodes a PCZT for transmission to an airgapped signer.
Uint8List encodeZcashPcztCbor(final Uint8List pczt) {
  final w = _CborWriter();
  w.map(1);
  w.uint(1);
  w.bytes(pczt);
  return w.take();
}

/// Extracts the PCZT bytes from a decoded `zcash-pczt` CBOR payload.
Uint8List decodeZcashPcztCbor(final Uint8List cbor) {
  final reader = _CborReader(cbor);
  final entries = reader.mapHeader();
  Uint8List? pczt;
  for (var i = 0; i < entries; i++) {
    final key = reader.uint();
    if (key == 1) {
      pczt = reader.bytes();
    } else {
      reader.skip();
    }
  }
  if (pczt == null) {
    throw Exception("zcash-pczt payload has no data field");
  }
  return pczt;
}

/// Reassembles animated `ur:zcash-pczt` frames into the PCZT bytes they carry.
Uint8List decodeZcashPcztFrames(final List<String> urCodes) {
  final decoder = URDecoder();
  for (final part in urCodes) {
    decoder.receivePart(part.trim());
  }
  if (!decoder.isComplete()) {
    throw Exception("incomplete zcash-pczt UR: scan every frame");
  }
  final result = decoder.result;
  if (result is! UR) {
    throw Exception("failed to decode zcash-pczt UR: $result");
  }
  if (result.type != zcashPcztUrType) {
    throw Exception("expected a $zcashPcztUrType UR, got ${result.type}");
  }
  return decodeZcashPcztCbor(result.cbor);
}

/// Reassembles animated `ur:zcash-accounts` frames into the account payload.
ZcashAccountsPayload decodeZcashAccountsFrames(final List<String> urCodes) {
  final decoder = URDecoder();
  for (final part in urCodes) {
    decoder.receivePart(part.trim());
  }
  if (!decoder.isComplete()) {
    throw Exception("incomplete zcash-accounts UR: scan every frame");
  }
  final result = decoder.result;
  if (result is! UR) {
    throw Exception("failed to decode zcash-accounts UR: $result");
  }
  if (result.type != zcashAccountsUrType) {
    throw Exception("expected a $zcashAccountsUrType UR, got ${result.type}");
  }
  return decodeZcashAccountsCbor(result.cbor);
}

/// Parses a `zcash-accounts` CBOR payload exported by Keystone or Cupcake.
///
/// Only the first unified full viewing key is returned; Keystone exports one
/// per account and Cake tracks a single account per wallet.
ZcashAccountsPayload decodeZcashAccountsCbor(final Uint8List cbor) {
  final reader = _CborReader(cbor);
  final entries = reader.mapHeader();
  Uint8List? fingerprint;
  String? ufvk;
  int accountIndex = 0;
  String? name;

  for (var i = 0; i < entries; i++) {
    final key = reader.uint();
    switch (key) {
      case 1:
        fingerprint = reader.bytes();
      case 2:
        final count = reader.arrayHeader();
        for (var j = 0; j < count; j++) {
          final tag = reader.tag();
          if (tag != zcashUfvkCborTag) {
            throw Exception("unexpected CBOR tag $tag in zcash-accounts");
          }
          final fields = reader.mapHeader();
          String? entryUfvk;
          int entryIndex = 0;
          String? entryName;
          for (var k = 0; k < fields; k++) {
            final fieldKey = reader.uint();
            switch (fieldKey) {
              case 1:
                entryUfvk = reader.text();
              case 2:
                entryIndex = reader.uint();
              case 3:
                entryName = reader.text();
              default:
                reader.skip();
            }
          }
          // Keep the first key; skip any extras.
          if (ufvk == null && entryUfvk != null) {
            ufvk = entryUfvk;
            accountIndex = entryIndex;
            name = entryName;
          }
        }
      default:
        reader.skip();
    }
  }

  if (fingerprint == null || ufvk == null) {
    throw Exception("zcash-accounts payload is missing the fingerprint or UFVK");
  }
  return ZcashAccountsPayload(
    seedFingerprint: fingerprint,
    ufvk: ufvk,
    accountIndex: accountIndex,
    name: name,
  );
}
