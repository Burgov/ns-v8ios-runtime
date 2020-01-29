// Copyright 2016 the V8 project authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef V8_INSPECTOR_STRING_UTIL_H_
#define V8_INSPECTOR_STRING_UTIL_H_

#include <stdint.h>
#include <memory>

#include "src/base/logging.h"
#include "src/base/macros.h"
#include "src/inspector/string-16.h"

#include "include/v8-inspector.h"

namespace v8_inspector {

namespace protocol {

class Value;

using String = v8_inspector::String16;
using StringBuilder = v8_inspector::String16Builder;

class StringUtil {
 public:
  static String substring(const String& s, size_t pos, size_t len) {
    return s.substring(pos, len);
  }
  static String fromInteger(int number) { return String::fromInteger(number); }
  static String fromInteger(size_t number) {
    return String::fromInteger(number);
  }
  static String fromDouble(double number) { return String::fromDouble(number); }
  static double toDouble(const char* s, size_t len, bool* isOk);
  static size_t find(const String& s, const char* needle) {
    return s.find(needle);
  }
  static size_t find(const String& s, const String& needle) {
    return s.find(needle);
  }
  static const size_t kNotFound = String::kNotFound;
  static void builderAppend(
      StringBuilder& builder,  // NOLINT(runtime/references)
      const String& s) {
    builder.append(s);
  }
  static void builderAppend(
      StringBuilder& builder,  // NOLINT(runtime/references)
      UChar c) {
    builder.append(c);
  }
  static void builderAppend(
      StringBuilder& builder,  // NOLINT(runtime/references)
      const char* s, size_t len) {
    builder.append(s, len);
  }
  static void builderReserve(
      StringBuilder& builder,  // NOLINT(runtime/references)
      size_t capacity) {
    builder.reserveCapacity(capacity);
  }
  static String builderToString(
      StringBuilder& builder) {  // NOLINT(runtime/references)
    return builder.toString();
  }
  static std::unique_ptr<protocol::Value> parseJSON(const String16& json);
  static std::unique_ptr<protocol::Value> parseJSON(const StringView& json);

  static String fromUTF8(const uint8_t* data, size_t length) {
    return String16::fromUTF8(reinterpret_cast<const char*>(data), length);
  }

  static String fromUTF16LE(const uint16_t* data, size_t length) {
    return String16::fromUTF16LE(data, length);
  }

  static const uint8_t* CharactersLatin1(const String& s) { return nullptr; }
  static const uint8_t* CharactersUTF8(const String& s) { return nullptr; }
  static const uint16_t* CharactersUTF16(const String& s) {
    return s.characters16();
  }
  static size_t CharacterCount(const String& s) { return s.length(); }
};

// A read-only sequence of uninterpreted bytes with reference-counted storage.
// Though the templates for generating the protocol bindings reference
// this type, js_protocol.pdl doesn't have a field of type 'binary', so
// therefore it's unnecessary to provide an implementation here.
class Binary {
 public:
  Binary() = default;

  void AppendSerialized(std::vector<uint8_t>* out) const {
    v8_crdtp::cbor::EncodeBinary(v8_crdtp::span<uint8_t>(data(), size()), out);
  }

  const uint8_t* data() const { return bytes_->data(); }
  size_t size() const { return bytes_->size(); }
  String toBase64() const { UNIMPLEMENTED(); }
  static Binary fromBase64(const String& base64, bool* success) {
    UNIMPLEMENTED();
  }
  static Binary fromSpan(const uint8_t* data, size_t size) {
    return Binary(std::make_shared<std::vector<uint8_t>>(data, data + size));
  }

 private:
  std::shared_ptr<std::vector<uint8_t>> bytes_;

  explicit Binary(std::shared_ptr<std::vector<uint8_t>> bytes)
      : bytes_(bytes) {}
};
}  // namespace protocol

v8::Local<v8::String> toV8String(v8::Isolate*, const String16&);
v8::Local<v8::String> toV8StringInternalized(v8::Isolate*, const String16&);
v8::Local<v8::String> toV8StringInternalized(v8::Isolate*, const char*);
v8::Local<v8::String> toV8String(v8::Isolate*, const StringView&);
// TODO(dgozman): rename to toString16.
String16 toProtocolString(v8::Isolate*, v8::Local<v8::String>);
String16 toProtocolStringWithTypeCheck(v8::Isolate*, v8::Local<v8::Value>);
String16 toString16(const StringView&);
StringView toStringView(const String16&);
bool stringViewStartsWith(const StringView&, const char*);

// Creates a string buffer instance which owns |str|, a 16 bit string.
std::unique_ptr<StringBuffer> StringBufferFrom(String16 str);

// Creates a string buffer instance which owns |str|, an 8 bit string.
// 8 bit strings are used for LATIN1 text (which subsumes 7 bit ASCII, e.g.
// our generated JSON), as well as for CBOR encoded binary messages.
std::unique_ptr<StringBuffer> StringBufferFrom(std::vector<uint8_t> str);

String16 stackTraceIdToString(uintptr_t id);

}  //  namespace v8_inspector

#endif  // V8_INSPECTOR_STRING_UTIL_H_
