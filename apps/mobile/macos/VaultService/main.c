// This service deliberately stays byte-identical when the Flutter app changes.
// File-based Keychain partitions identify locally signed code by its CDHash.
// A private, immutable XPC service therefore owns the single master-key read.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

#ifndef HM_VAULT_CLIENT_REQUIREMENT
#error "Build with an explicit client identifier and certificate requirement"
#endif

#ifdef HM_VAULT_SYNTHETIC_TEST
#ifndef HM_VAULT_KEYCHAIN_SERVICE
#error "Synthetic builds must use a distinct, non-production service"
#endif
#ifndef HM_VAULT_KEYCHAIN_ACCOUNT
#error "Synthetic builds must use a distinct, non-production account"
#endif
#define HM_VAULT_NEW_ACCOUNT HM_VAULT_KEYCHAIN_ACCOUNT "-v2"
#define HM_VAULT_MARKER_ACCOUNT HM_VAULT_KEYCHAIN_ACCOUNT "-committed"
#else
#if defined(HM_VAULT_KEYCHAIN_SERVICE) || defined(HM_VAULT_KEYCHAIN_ACCOUNT)
#error "Production Keychain names are fixed, never supplied by a caller"
#endif
#define HM_VAULT_KEYCHAIN_SERVICE "com.nearlink.chat"
#define HM_VAULT_KEYCHAIN_ACCOUNT "mac-vault-master-v1"
#define HM_VAULT_NEW_ACCOUNT "mac-vault-master-v2"
#define HM_VAULT_MARKER_ACCOUNT "mac-vault-master-v2-initialized"
#endif

enum { kMasterSize = 32, kProtocolVersion = 1 };
static dispatch_queue_t vault_queue;
static const uint8_t committed_marker[] = "hello-mentor-vault:v2:committed";

static CFMutableDictionaryRef item_query(CFStringRef account) {
    CFMutableDictionaryRef query = CFDictionaryCreateMutable(kCFAllocatorDefault,
        0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!query) return NULL;
    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, CFSTR(HM_VAULT_KEYCHAIN_SERVICE));
    CFDictionarySetValue(query, kSecAttrAccount, account);
    CFDictionarySetValue(query, kSecUseDataProtectionKeychain, kCFBooleanFalse);
    return query;
}

static OSStatus read_item(CFStringRef account, bool allow_ui, CFIndex size, CFDataRef *result) {
    *result = NULL;
    CFMutableDictionaryRef query = item_query(account);
    if (!query) return errSecAllocate;
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
    if (!allow_ui) {
        CFDictionarySetValue(query, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
    }
    CFTypeRef value = NULL;
    OSStatus status = SecItemCopyMatching(query, &value);
    CFRelease(query);
    if (status == errSecSuccess) {
        if (!value || CFGetTypeID(value) != CFDataGetTypeID() ||
            CFDataGetLength((CFDataRef)value) != size) {
            status = errSecDecode;
        } else {
            *result = (CFDataRef)value;
            value = NULL;
        }
    }
    if (value) CFRelease(value);
    return status;
}

static OSStatus add_item(CFStringRef account, CFDataRef data, bool is_marker) {
    CFMutableDictionaryRef attributes = item_query(account);
    if (!attributes) return errSecAllocate;
    CFDictionarySetValue(attributes, kSecValueData, data);
    CFDictionarySetValue(attributes, kSecAttrLabel, CFSTR("导师好 · 本机密钥库"));
    CFDictionarySetValue(attributes, kSecAttrDescription, is_marker
        ? CFSTR("本机密钥迁移完成标记（不含密钥）") : CFSTR("保护此设备的身份与群密钥"));
    CFDictionarySetValue(attributes, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
    // New items receive this immutable helper's default creator ACL. Existing
    // items and their ACLs are never overwritten, deleted, or relaxed.
    OSStatus status = SecItemAdd(attributes, NULL);
    CFRelease(attributes);
    return status;
}

static OSStatus read_marker(bool *exists) {
    *exists = false;
    CFDataRef marker = NULL;
    OSStatus status = read_item(CFSTR(HM_VAULT_MARKER_ACCOUNT), false,
                               sizeof(committed_marker) - 1, &marker);
    if (status == errSecItemNotFound) return errSecSuccess;
    if (status != errSecSuccess) return status;
    if (memcmp(CFDataGetBytePtr(marker), committed_marker, sizeof(committed_marker) - 1) != 0) {
        status = errSecDecode;
    } else {
        *exists = true;
    }
    CFRelease(marker);
    return status;
}

static OSStatus ensure_marker(void) {
    bool exists = false;
    OSStatus status = read_marker(&exists);
    if (status != errSecSuccess || exists) return status;
    CFDataRef marker = CFDataCreate(kCFAllocatorDefault, committed_marker,
                                   sizeof(committed_marker) - 1);
    if (!marker) return errSecAllocate;
    status = add_item(CFSTR(HM_VAULT_MARKER_ACCOUNT), marker, true);
    CFRelease(marker);
    // A concurrent helper may have added the same fixed marker. It still has
    // to be readable without UI and contain exactly the expected version.
    if (status != errSecSuccess && status != errSecDuplicateItem) return status;
    status = read_marker(&exists);
    if (status != errSecSuccess) return status;
    return exists ? errSecSuccess : errSecDecode;
}

// Only this function may report "not found" to the Dart vault. That result
// means BOTH v2 and its commit marker are absent, never a broken committed key.
static OSStatus read_current_master(CFDataRef *result) {
    *result = NULL;
    bool committed = false;
    OSStatus status = read_marker(&committed);
    if (status != errSecSuccess) return status;
    CFDataRef saved = NULL;
    status = read_item(CFSTR(HM_VAULT_NEW_ACCOUNT), false, kMasterSize, &saved);
    if (status == errSecItemNotFound) return committed ? errSecDecode : errSecItemNotFound;
    if (status != errSecSuccess) return status;
    // Recover a crash after the v2 item was saved but before its marker. This
    // commits only the Keychain location; the app must still authenticate its
    // encrypted vault and must never reset an identity after decryption fails.
    if (!committed) status = ensure_marker();
    if (status == errSecSuccess) *result = saved;
    else CFRelease(saved);
    return status;
}

static OSStatus persist_master(CFDataRef source, CFDataRef *result) {
    *result = NULL;
    OSStatus status = add_item(CFSTR(HM_VAULT_NEW_ACCOUNT), source, false);
    if (status != errSecSuccess && status != errSecDuplicateItem) return status;
    CFDataRef saved = NULL;
    status = read_item(CFSTR(HM_VAULT_NEW_ACCOUNT), false, kMasterSize, &saved);
    // A missing item after Add is an integrity error, never "new installation".
    if (status == errSecItemNotFound) return errSecDecode;
    if (status != errSecSuccess) return status;
    if (!CFEqual(saved, source)) status = errSecDecode;
    if (status == errSecSuccess) status = ensure_marker();
    if (status == errSecSuccess) *result = saved;
    else CFRelease(saved);
    return status;
}

static OSStatus read_master(bool allow_legacy_ui, CFDataRef *result) {
    OSStatus status = read_current_master(result);
    if (status != errSecItemNotFound) return status;
    // This is the only production secret lookup which may show a dialog.
    // Migration keeps the same bytes and leaves the old item untouched.
    CFDataRef legacy = NULL;
    status = read_item(CFSTR(HM_VAULT_KEYCHAIN_ACCOUNT), allow_legacy_ui,
                       kMasterSize, &legacy);
    if (status != errSecSuccess) return status;
    status = persist_master(legacy, result);
    CFRelease(legacy);
    return status;
}

static OSStatus create_master(CFDataRef *result) {
    *result = NULL;
    CFDataRef existing = NULL;
    OSStatus status = read_current_master(&existing);
    if (status == errSecSuccess) {
        CFRelease(existing);
        return errSecDuplicateItem;
    }
    if (status != errSecItemNotFound) return status;
    status = read_item(CFSTR(HM_VAULT_KEYCHAIN_ACCOUNT), false, kMasterSize, &existing);
    if (status == errSecSuccess) {
        CFRelease(existing);
        return errSecDuplicateItem;
    }
    if (status != errSecItemNotFound) return status;
    uint8_t bytes[kMasterSize] = {0};
#ifdef HM_VAULT_SYNTHETIC_TEST
    // Different from the legacy fixture, so tests detect accidental rotation.
    memset(bytes, 0x42, sizeof(bytes));
    status = errSecSuccess;
#else
    status = SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes);
#endif
    if (status != errSecSuccess) return status;
    CFDataRef generated = CFDataCreate(kCFAllocatorDefault, bytes, sizeof(bytes));
    volatile uint8_t *erase = bytes;
    for (size_t index = 0; index < sizeof(bytes); ++index) erase[index] = 0;
    if (!generated) return errSecAllocate;
    status = persist_master(generated, result);
    CFRelease(generated);
    return status;
}

#ifdef HM_VAULT_SYNTHETIC_TEST
static OSStatus delete_test_item(CFStringRef account) {
    CFMutableDictionaryRef query = item_query(account);
    if (!query) return errSecAllocate;
    OSStatus status = SecItemDelete(query);
    CFRelease(query);
    return status == errSecItemNotFound ? errSecSuccess : status;
}

static OSStatus add_test_bytes(CFStringRef account, uint8_t value, CFIndex size) {
    uint8_t bytes[kMasterSize];
    memset(bytes, value, sizeof(bytes));
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, size);
    if (!data) return errSecAllocate;
    OSStatus status = add_item(account, data, false);
    CFRelease(data);
    return status;
}

static OSStatus corrupt_test_item(CFStringRef account) {
    OSStatus status = delete_test_item(account);
    return status == errSecSuccess ? add_test_bytes(account, 0x58, 3) : status;
}

static OSStatus cleanup_test_items(void) {
    const CFStringRef accounts[] = {CFSTR(HM_VAULT_KEYCHAIN_ACCOUNT),
        CFSTR(HM_VAULT_NEW_ACCOUNT), CFSTR(HM_VAULT_MARKER_ACCOUNT)};
    OSStatus result = errSecSuccess;
    for (size_t i = 0; i < sizeof(accounts) / sizeof(accounts[0]); ++i) {
        OSStatus status = delete_test_item(accounts[i]);
        if (status != errSecSuccess) result = status;
    }
    return result;
}
#endif

static bool valid_request(xpc_object_t message) {
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY ||
        xpc_dictionary_get_count(message) != 2) return false;
    xpc_object_t version = xpc_dictionary_get_value(message, "version");
    xpc_object_t operation = xpc_dictionary_get_value(message, "operation");
    return version && operation && xpc_get_type(version) == XPC_TYPE_INT64 &&
        xpc_int64_get_value(version) == kProtocolVersion &&
        xpc_get_type(operation) == XPC_TYPE_STRING;
}

static void handle_message(xpc_connection_t peer, xpc_object_t message) {
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    // Do no Keychain work for a fire-and-forget or malformed request.
    if (!reply) return;
    OSStatus status = errSecParam;
    CFDataRef master = NULL;
    if (valid_request(message)) {
        const char *operation = xpc_dictionary_get_string(message, "operation");
        if (strcmp(operation, "readMaster") == 0) {
            status = read_master(true, &master);
        } else if (strcmp(operation, "createMaster") == 0) {
            status = create_master(&master);
        }
#ifdef HM_VAULT_SYNTHETIC_TEST
        else if (strcmp(operation, "readMasterNoUI") == 0) {
            status = read_master(false, &master);
        } else if (strcmp(operation, "deleteSyntheticMaster") == 0) {
            status = cleanup_test_items();
        } else if (strcmp(operation, "seedSyntheticLegacyMaster") == 0) {
            status = add_test_bytes(CFSTR(HM_VAULT_KEYCHAIN_ACCOUNT), 0x4c, kMasterSize);
        } else if (strcmp(operation, "readSyntheticLegacyMaster") == 0) {
            status = read_item(CFSTR(HM_VAULT_KEYCHAIN_ACCOUNT), false, kMasterSize, &master);
        } else if (strcmp(operation, "stageSyntheticNewMaster") == 0) {
            status = add_test_bytes(CFSTR(HM_VAULT_NEW_ACCOUNT), 0x4c, kMasterSize);
        } else if (strcmp(operation, "deleteSyntheticNewMaster") == 0) {
            status = delete_test_item(CFSTR(HM_VAULT_NEW_ACCOUNT));
        } else if (strcmp(operation, "corruptSyntheticNewMaster") == 0) {
            status = corrupt_test_item(CFSTR(HM_VAULT_NEW_ACCOUNT));
        } else if (strcmp(operation, "deleteSyntheticMarker") == 0) {
            status = delete_test_item(CFSTR(HM_VAULT_MARKER_ACCOUNT));
        } else if (strcmp(operation, "corruptSyntheticMarker") == 0) {
            status = corrupt_test_item(CFSTR(HM_VAULT_MARKER_ACCOUNT));
        } else if (strcmp(operation, "createSyntheticMarkerOnly") == 0) {
            status = ensure_marker();
        } else if (strcmp(operation, "deleteSyntheticLegacyMaster") == 0) {
            status = delete_test_item(CFSTR(HM_VAULT_KEYCHAIN_ACCOUNT));
        } else if (strcmp(operation, "corruptSyntheticLegacyMaster") == 0) {
            status = corrupt_test_item(CFSTR(HM_VAULT_KEYCHAIN_ACCOUNT));
        }
#endif
    }
    xpc_dictionary_set_int64(reply, "version", kProtocolVersion);
    xpc_dictionary_set_int64(reply, "status", status);
    if (status == errSecSuccess && master) {
        xpc_dictionary_set_data(reply, "master", CFDataGetBytePtr(master), kMasterSize);
    }
    if (master) CFRelease(master);
    xpc_connection_send_message(peer, reply);
    xpc_release(reply);
}

static void accept_connection(xpc_connection_t peer) {
    // This public API checks each incoming message's actual code identity,
    // without PID races or a private audit-token API. Available on macOS12+.
    if (xpc_connection_set_peer_code_signing_requirement(peer,
            HM_VAULT_CLIENT_REQUIREMENT) != 0) {
        xpc_connection_cancel(peer);
        return;
    }
    xpc_connection_set_target_queue(peer, vault_queue);
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
        handle_message(peer, message);
    });
    xpc_connection_resume(peer);
}

int main(void) {
#ifdef HM_VAULT_SYNTHETIC_TEST
    // Synthetic tests must never cause an OS password dialog.
    if (SecKeychainSetUserInteractionAllowed(false) != errSecSuccess) return EXIT_FAILURE;
    if (strcmp(HM_VAULT_KEYCHAIN_SERVICE, "com.nearlink.chat") == 0 ||
        strncmp(HM_VAULT_KEYCHAIN_ACCOUNT, "probe-", 6) != 0) return EXIT_FAILURE;
#endif
    vault_queue = dispatch_queue_create("com.nearlink.chat.vault-service", DISPATCH_QUEUE_SERIAL);
    if (!vault_queue) return EXIT_FAILURE;
    xpc_main(accept_connection);
}
