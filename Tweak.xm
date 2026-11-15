#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <CoreGraphics/CoreGraphics.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <string.h>

// Khai báo các hàm IL2CPP
void* (*il2cpp_domain_get)();
void** (*il2cpp_domain_get_assemblies)(void*, size_t*);
void* (*il2cpp_assembly_get_image)(void*);
size_t (*il2cpp_image_get_class_count)(void*);
void* (*il2cpp_image_get_class)(void*, size_t);
const char* (*il2cpp_class_get_name)(void*);
void* (*il2cpp_class_get_methods)(void*, void**);
const char* (*il2cpp_method_get_name)(void*);
void* (*il2cpp_method_get_pointer)(void*);

// Hàm lấy danh sách người chơi
void* (*get_PlayerListOthers)() = NULL;

// Hàm đọc bộ nhớ an toàn
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
    [super drawRect:rect];
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;
    
    CGContextSetStrokeColorWithColor(context, [UIColor redColor].CGColor);
    CGContextSetLineWidth(context, 1.0);
    CGFloat radius = 150.0;
    CGRect circleRect = CGRectMake(self.bounds.size.width/2 - radius, self.bounds.size.height/2 - radius, radius*2, radius*2);
    CGContextStrokeEllipseInRect(context, circleRect);
}
@end

// --- HOOK CAMERA UPDATE ---
typedef void (*CameraUpdate_t)(void* self);
CameraUpdate_t orig_CameraUpdate = NULL;

void hook_CameraUpdate(void* self) {
    orig_CameraUpdate(self);
    
    if (!get_PlayerListOthers) return;
    
    // Gọi hàm lấy danh sách địch
    void* playerArray = get_PlayerListOthers();
    if (!playerArray) return;
    
    // Đọc độ dài mảng (offset 0x18)
    int length = 0;
    if (safe_read((uint64_t)playerArray + 0x18, length)) {
        if (length > 0) {
            NSLog(@"[SafeTest] Tim thay %d nguoi choi khac!", length);
        }
    }
}

// --- KHỞI TẠO ---
__attribute__((constructor))
static void init() {
    // 1. Vẽ vòng tròn FOV lên màn hình
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (window) {
            FovView *fov = [[FovView alloc] initWithFrame:window.bounds];
            fov.backgroundColor = [UIColor clearColor];
            fov.userInteractionEnabled = NO;
            [window addSubview:fov];
            NSLog(@"[SafeTest] Da ve vong tron FOV");
        }
    });

    // 2. Tìm và Hook game
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

                // Tìm PhotonNetwork để lấy danh sách địch
                if (strcmp(clsName, "PhotonNetwork") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = il2cpp_class_get_methods(cls, &iter))) {
                        const char* mName = il2cpp_method_get_name(method);
                        if (mName && strcmp(mName, "get_PlayerListOthers") == 0) {
                            get_PlayerListOthers = (void*(*)())il2cpp_method_get_pointer(method);
                            NSLog(@"[SafeTest] Da tim thay ham lay danh sach dich!");
                        }
                    }
                }

                // Tìm PlayerCamera để Hook
                if (strcmp(clsName, "PlayerCamera") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = il2cpp_class_get_methods(cls, &iter))) {
                        const char* mName = il2cpp_method_get_name(method);
                        if (mName && strstr(mName, "LateUpdate")) {
                            void* ptr = il2cpp_method_get_pointer(method);
                            if (ptr && !orig_CameraUpdate) {
                                MSHookFunction(ptr, (void*)hook_CameraUpdate, (void**)&orig_CameraUpdate);
                                NSLog(@"[SafeTest] Da Hook thanh cong vao Camera!");
                            }
                        }
                    }
                }
            }
        }
    });
}
