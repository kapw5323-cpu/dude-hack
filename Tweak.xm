#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <string.h>

// --- ĐỊNH NGHĨA CẤU TRÚC TỌA ĐỘ (Đã thêm vào đây) ---
struct Vector3 { float x, y, z; };

// --- CÁC HÀM IL2CPP CẦN THIẾT ---
void* (*il2cpp_domain_get)();
void** (*il2cpp_domain_get_assemblies)(void*, size_t*);
void* (*il2cpp_assembly_get_image)(void*);
void* (*il2cpp_class_from_name)(void*, const char*, const char*);
void* (*il2cpp_class_get_field_from_name)(void*, const char*);
void (*il2cpp_field_static_get_value)(void*, void*);
void* (*il2cpp_class_get_methods)(void*, void**);
const char* (*il2cpp_method_get_name)(void*);
void* (*il2cpp_method_get_pointer)(void*);
const char* (*il2cpp_image_get_name)(void*);

// --- CON TRỎ HÀM GAME ---
void (*WorldToScreenPoint)(void* cam, Vector3 pos, Vector3* ret) = NULL;
void* (*get_mainCamera)() = NULL;

uint64_t mgrInstance = 0;
dispatch_source_t timer = NULL;

// Hàm đọc an toàn
template <typename T> bool safe_read(uint64_t addr, T& out) {
    if (!addr) return false;
    vm_size_t size = 0;
    return vm_read_overwrite(mach_task_self(), addr, sizeof(T), (vm_address_t)&out, &size) == KERN_SUCCESS;
}

// Hàm ghi log ra file
void LogToFile(NSString *text) {
    NSString *path = @"/var/mobile/dude_log.txt";
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForUpdatingAtPath:path];
    [fh seekToEndOfFile];
    [fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// --- HÀM CHẠY NGẦM QUÉT BỘ NHỚ ---
void ReadMemoryTask() {
    if (mgrInstance == 0) return;

    uint64_t listPtr = 0;
    // Đọc otherPlayers (0x70)
    if (!safe_read(mgrInstance + 0x70, listPtr) || !listPtr) return;

    uint64_t arrayPtr = 0;
    int32_t length = 0;
    // Đọc mảng List
    if (!safe_read(listPtr + 0x10, arrayPtr) || !safe_read(listPtr + 0x18, length)) return;
    if (length <= 0 || length > 64) return;

    NSString *logStr = [NSString stringWithFormat:@"\n[Time] %@ - Phat hien %d nguoi choi:\n", [NSDate date], length];

    for (int i = 0; i < length; i++) {
        uint64_t trans = 0;
        if (!safe_read(arrayPtr + 0x20 + (i * 8), trans) || !trans) continue;
        
        // Đọc vị trí X, Y, Z (0x38)
        Vector3 pos = {0, 0, 0};
        if (!safe_read(trans + 0x38, pos)) continue;
        
        // Bỏ qua tọa độ rác
        if (pos.x == 0 && pos.y == 0 && pos.z == 0) continue;

        logStr = [logStr stringByAppendingFormat:@"  Dich %d: X=%.1f, Y=%.1f, Z=%.1f\n", i, pos.x, pos.y, pos.z];
    }

    LogToFile(logStr);
}

__attribute__((constructor))
static void init() {
    // 1. Lấy các hàm IL2CPP từ hệ thống
    void* h = dlopen(NULL, RTLD_LAZY);
    if (!h) return;
    
    il2cpp_domain_get = (void*(*)())dlsym(h, "il2cpp_domain_get");
    il2cpp_domain_get_assemblies = (void**(*)(void*, size_t*))dlsym(h, "il2cpp_domain_get_assemblies");
    il2cpp_assembly_get_image = (void*(*)(void*))dlsym(h, "il2cpp_assembly_get_image");
    il2cpp_class_from_name = (void*(*)(void*, const char*, const char*))dlsym(h, "il2cpp_class_from_name");
    il2cpp_class_get_field_from_name = (void*(*)(void*, const char*))dlsym(h, "il2cpp_class_get_field_from_name");
    il2cpp_field_static_get_value = (void(*)(void*, void*))dlsym(h, "il2cpp_field_static_get_value");
    il2cpp_class_get_methods = (void*(*)(void*, void**))dlsym(h, "il2cpp_class_get_methods");
    il2cpp_method_get_name = (const char*(*)(void*))dlsym(h, "il2cpp_method_get_name");
    il2cpp_method_get_pointer = (void*(*)(void*))dlsym(h, "il2cpp_method_get_pointer");
    il2cpp_image_get_name = (const char*(*)(void*))dlsym(h, "il2cpp_image_get_name");

    if (!il2cpp_domain_get) return;

    // 2. Quét tìm Class MPGameManager để lấy Instance
    size_t count = 0;
    void** asms = il2cpp_domain_get_assemblies(il2cpp_domain_get(), &count);
    for (size_t i = 0; i < count; i++) {
        void* img = il2cpp_assembly_get_image(asms[i]);
        const char* imgName = il2cpp_image_get_name(img);
        if (!imgName || strstr(imgName, "Assembly-CSharp") == NULL) continue;

        void* cls = il2cpp_class_from_name(img, "", "MPGameManager");
        if (cls) {
            // Lấy trường Instance (static)
            void* field = il2cpp_class_get_field_from_name(cls, "Instance");
            if (field) {
                il2cpp_field_static_get_value(field, &mgrInstance);
            }
            
            // Lấy các hàm Camera
            void* iter = NULL; void* method;
            while ((method = il2cpp_class_get_methods(cls, &iter))) {
                // Tìm hàm lấy main camera
                if (strcmp(il2cpp_method_get_name(method), "get_main") == 0) {
                    get_mainCamera = (void*(*)())il2cpp_method_get_pointer(method);
                }
            }
        }
        
        // Lấy hàm WorldToScreenPoint từ class Camera
        void* camCls = il2cpp_class_from_name(img, "UnityEngine", "Camera");
        if (camCls) {
             void* iter = NULL; void* method;
             while ((method = il2cpp_class_get_methods(camCls, &iter))) {
                 if (strcmp(il2cpp_method_get_name(method), "WorldToScreenPoint") == 0) {
                     WorldToScreenPoint = (void(*)(void*, Vector3, Vector3*))il2cpp_method_get_pointer(method);
                 }
             }
        }
    }

    if (mgrInstance == 0) {
        LogToFile(@"\n[Loi] Khong tim thay MPGameManager Instance!");
        return;
    }

    LogToFile(@"\n[OK] Da tim thay MPGameManager! Bat dau quet...");

    // 3. Tạo Timer chạy 10fps (chậm thôi để tuyệt đối an toàn)
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 10.0, 0);
    dispatch_source_set_event_handler(timer, ^{
        ReadMemoryTask();
    });
    dispatch_resume(timer);
}
