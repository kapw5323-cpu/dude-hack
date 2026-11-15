#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#include <dlfcn.h>
#include <vector>
#include <cmath>
#include <string.h>
#include <mach/mach.h>

#define OFF_LOCALPLAYER  0xF8
#define OFF_OTHERPLAYERS 0x70
#define OFF_HEALTH       0x28
#define OFF_YAW          0x44
#define OFF_PITCH        0x40
#define OFF_POSITION     0x38

struct Vec3 { float x, y, z; };

template <typename T> bool rd(uint64_t addr, T& out) {
    if (!addr) return false;
    vm_size_t size = 0;
    return vm_read_overwrite(mach_task_self(), addr, sizeof(T), (vm_address_t)&out, &size) == KERN_SUCCESS;
}

template <typename T> bool wr(uint64_t addr, const T& in) {
    if (!addr) return false;
    return vm_write(mach_task_self(), addr, (vm_address_t)&in, sizeof(T)) == KERN_SUCCESS;
}

void* (*il2cpp_domain_get)();
void** (*il2cpp_domain_get_assemblies)(void*, size_t*);
void* (*il2cpp_assembly_get_image)(void*);
size_t (*il2cpp_image_get_class_count)(void*);
void* (*il2cpp_image_get_class)(void*, size_t);
const char* (*il2cpp_class_get_name)(void*);
void* (*il2cpp_class_get_methods)(void*, void**);
const char* (*il2cpp_method_get_name)(void*);
void* (*il2cpp_method_get_pointer)(void*);

typedef void (*CamUpdate_t)(void* self);
CamUpdate_t orig_CamUpdate = NULL;

void hook_CamUpdate(void* self) {
    orig_CamUpdate(self);
    
    float curYaw = 0, curPitch = 0;
    if (!rd((uint64_t)self + OFF_YAW, curYaw) || !rd((uint64_t)self + OFF_PITCH, curPitch)) return;
    
    // TEST: Tự động kéo tâm ngẩng lên một chút
    float newPitch = curPitch - 0.05f; 
    wr((uint64_t)self + OFF_PITCH, newPitch);
}

__attribute__((constructor))
static void init() {
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
                if (clsName && strstr(clsName, "PlayerCamera")) {
                    void* iter = NULL;
                    void* method;
                    while ((method = il2cpp_class_get_methods(cls, &iter))) {
                        const char* mName = il2cpp_method_get_name(method);
                        if (mName && (strstr(mName, "Update") || strstr(mName, "LateUpdate"))) {
                            void* ptr = il2cpp_method_get_pointer(method);
                            if (ptr) {
                                MSHookFunction(ptr, (void*)hook_CamUpdate, (void**)&orig_CamUpdate);
                                NSLog(@"[DudeHack] Hooked %s::%s", clsName, mName);
                            }
                        }
                    }
                }
            }
        }
    });
}
