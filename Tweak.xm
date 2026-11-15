#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <cmath>
#include <string.h>
#include <vector>

#define OFF_HEALTH 0x28
#define OFF_POSITION 0x50

struct Vector3 { float x, y, z; };

// Các hàm IL2CPP
void* (*il2cpp_domain_get)();
void** (*il2cpp_domain_get_assemblies)(void*, size_t*);
void* (*il2cpp_assembly_get_image)(void*);
size_t (*il2cpp_image_get_class_count)(void*);
void* (*il2cpp_image_get_class)(void*, size_t);
const char* (*il2cpp_class_get_name)(void*);
void* (*il2cpp_class_get_methods)(void*, void**);
const char* (*il2cpp_method_get_name)(void*);
void* (*il2cpp_method_get_pointer)(void*);

// Hàm lấy danh sách địch
void* (*get_PlayerListOthers)() = NULL;

template <typename T> bool safe_read(uint64_t addr, T& out) {
    if (!addr) return false;
    vm_size_t size = 0;
    return vm_read_overwrite(mach_task_self(), addr, sizeof(T), (vm_address_t)&out, &size) == KERN_SUCCESS;
}

// --- VẼ VÒNG TRÒN FOV ---
@interface FovView : UIView
@end
@implementation FovView
- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(context, [UIColor redColor].CGColor);
    CGContextSetLineWidth(context, 1.0);
    CGFloat radius = 150.0;
    CGContextAddEllipseInRect(context, CGRectMake(self.bounds.size.width/2 - radius, self.bounds.size.height/2 - radius, radius*2, radius*2));
    CGContextStrokePath(context);
}
@end

// --- HOOK ĐỂ ĐẾM ĐỊCH ---
typedef void (*CameraUpdate_t)(void* self);
CameraUpdate_t orig_CameraUpdate = NULL;

void hook_CameraUpdate(void* self) {
    orig_CameraUpdate(self);
    
    if (!get_PlayerListOthers) return;
    
    // Gọi hàm lấy danh sách địch
    void* playerArray = get_PlayerListOthers();
    if (!playerArray) {
        NSLog(@"[SafeTest] Khong tim thay mang player");
        return;
    }
    
    // Đọc độ dài mảng (offset 0x18) và mảng items (offset 0x20)
    int length = 0;
    if (!safe_read((uint64_t)playerArray + 0x18, length)) {
        NSLog(@"[SafeTest] Loi doc length");
        return;
    }
    
    if (length > 0) {
        NSLog(@"[SafeTest] Tim thay %d nguoi choi!", length);
        // Chỉ in ra log, không làm gì thêm để chống văng
    }
}

__attribute__((constructor))
static void init() {
    // Bật vòng tròn FOV
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (window) {
            FovView *fov = [[FovView alloc] initWithFrame:window.bounds];
            fov.backgroundColor = [UIColor clearColor];
            fov.userInteractionEnabled = NO;
            [window addSubview:fov];
            NSLog(@"[SafeTest] Da ve vong tron FOV");
        }
    });
    
    // Tìm hàm Hook
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        il2cpp_domain_get = (void*(*)())dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
        il2cpp_domain_get_assemblies = (void**(*)(void*, size_t*))dlsym(RTLD_DEFAULT, "il2cpp_domain_get_assemblies");
        il2cpp_assembly_get_image = (void*(*)(void*))dlsym(RTLD_DEFAULT, "il2cpp_assembly_get_image");
        il2cpp_image_get_class_count = (size_t(*)(void*))dlsym(RTLD_DEFAULT, "il2cpp_image_get_class_count");
        il2cpp_image_get_class = (void*(*)(void*, size_t))dlsym(RTLD_DEFAULT, "il2cpp_image_get_class");
        il2cpp_class_get_name = (const char*(*)(void*))dlsym(RTLD_DEFAULT, "il2cpp_class_get_name");
        il2cpp_class_get_methods = (void*(*)(void*, void**))dlsym(RTLD_DEFAULT, "il2cpp_class_get_methods");
        il2cpp_method_get_name = (const char*(*)(void*))dlsym(RTLD_DEFAULT, "il2cpp_method_get_name");
        il2cpp_method_get_pointer = (void*(*)(void*))dlsym(RTLD_DEFAULT, "il2cpp_method_get_pointer");

        if (!il2cpp_domain_get) return;

        size_t count = 0;
        void** asms = il2cpp_domain_get_assemblies(il2cpp_domain_get(), &count);
        for (size_t i = 0; i < count; i++) {
            void* img = il2cpp_assembly_get_image(asms[i]);
            size_t clsCount = il2cpp_image_get_class_count(img);
            for (size_t j = 0; j < clsCount; j++) {
                void* cls = il2cpp_image_get_class(img, j);
                const char* clsName = il2cpp_class_get_name(cls);
                if (!clsName) continue;
                
                // Lấy hàm get_PlayerListOthers từ PhotonNetwork
                if (strcmp(clsName, "PhotonNetwork") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = il2cpp_class_get_methods(cls, &iter))) {
                        const char* mName = il2cpp_method_get_name(method);
                        if (mName && strcmp(mName, "get_PlayerListOthers") == 0) {
                            get_PlayerListOthers = (void*(*)())il2cpp_method_get_pointer(method);
                            NSLog(@"[SafeTest] Da tim thay get_PlayerListOthers!");
                        }
                    }
                }
                
                // Hook Camera
                if (strcmp(clsName, "PlayerCamera") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = il2cpp_class_get_methods(cls, &iter))) {
                        const char* mName = il2cpp_method_get_name(method);
                        if (mName && strstr(mName, "LateUpdate")) {
                            void* ptr = il2cpp_method_get_pointer(method);
                            if (ptr && !orig_CameraUpdate) {
                                MSHookFunction(ptr, (void*)hook_CameraUpdate, (void**)&orig_CameraUpdate);
                                NSLog(@"[SafeTest] Da Hook Camera!");
                            }
                        }
                    }
                }
            }
        }
    });
}
