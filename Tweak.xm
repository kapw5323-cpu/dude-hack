#import <Foundation/Foundation.h>
#import <substrate.h>
#include <dlfcn.h>
#include <string.h>

// Chỉ khai báo các hàm IL2CPP cơ bản
void* (*il2cpp_domain_get)();
void** (*il2cpp_domain_get_assemblies)(void*, size_t*);
void* (*il2cpp_assembly_get_image)(void*);
size_t (*il2cpp_image_get_class_count)(void*);
void* (*il2cpp_image_get_class)(void*, size_t);
const char* (*il2cpp_class_get_name)(void*);
void* (*il2cpp_class_get_methods)(void*, void**);
const char* (*il2cpp_method_get_name)(void*);
void* (*il2cpp_method_get_pointer)(void*);

typedef void (*Update_t)(void* self);
Update_t orig_Update = NULL;

void hook_Update(void* self) {
    orig_Update(self);
    // KHÔNG LÀM GÌ CẢ, CHỈ GỌI HÀM GỐC
}

__attribute__((constructor))
static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        void* h = dlopen(NULL, RTLD_LAZY);
        if (!h) return;
        
        il2cpp_domain_get = (void*(*)())dlsym(h, "il2cpp_domain_get");
        il2cpp_domain_get_assemblies = (void**(*)(void*, size_t*))dlsym(h, "il2cpp_domain_get_assemblies");
        il2cpp_assembly_get_image = (void*(*)(void*))dlsym(h, "il2cpp_assembly_get_image");
        il2cpp_image_get_class_count = (size_t(*)(void*))dlsym(h, "il2cpp_image_get_class_count");
        il2cpp_image_get_class = (void*(*)(void*, size_t))dlsym(h, "il2cpp_image_get_class");
        il2cpp_class_get_name = (const char*(*)(void*))dlsym(h, "il2cpp_class_get_name");
        il2cpp_class_get_methods = (void*(*)(void*, void**))dlsym(h, "il2cpp_class_get_methods");
        il2cpp_method_get_name = (const char*(*)(void*))dlsym(h, "il2cpp_method_get_name");
        il2cpp_method_get_pointer = (void*(*)(void*))dlsym(h, "il2cpp_method_get_pointer");

        if (!il2cpp_domain_get) return;
        size_t count = 0;
        void** asms = il2cpp_domain_get_assemblies(il2cpp_domain_get(), &count);
        
        for (size_t i = 0; i < count; i++) {
            void* img = il2cpp_assembly_get_image(asms[i]);
            size_t clsCount = il2cpp_image_get_class_count(img);
            for (size_t j = 0; j < clsCount; j++) {
                void* cls = il2cpp_image_get_class(img, j);
                const char* cName = il2cpp_class_get_name(cls);
                if (cName && strcmp(cName, "MPGameManager") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = il2cpp_class_get_methods(cls, &iter))) {
                        const char* mName = il2cpp_method_get_name(method);
                        if (mName && strcmp(mName, "Update") == 0) {
                            void* ptr = il2cpp_method_get_pointer(method);
                            if (ptr) {
                                MSHookFunction(ptr, (void*)hook_Update, (void**)&orig_Update);
                                NSLog(@"[Test A] Da hook MPGameManager.Update thanh cong!");
                            }
                        }
                    }
                }
            }
        }
    });
}
