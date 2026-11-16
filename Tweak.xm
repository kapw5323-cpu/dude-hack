#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <cmath>
#include <string.h>
#include <vector>

// --- OFFSET CHUẨN ---
#define OFF_PLAYER_AVATAR  0x40
#define OFF_OTHERPLAYERS   0x70
#define OFF_CAMERA_TRANS   0x20
#define OFF_YAW            0x68
#define OFF_PITCH          0x64
#define OFF_POSITION       0x38

// --- CẤU HÌNH ---
bool isAimEnabled = true; 
float aimSmooth = 0.35f;

struct Vector3 { float x, y, z; };

// Hàm game
void (*WorldToScreenPoint)(void* cam, Vector3 pos, Vector3* ret) = NULL;
void* (*get_mainCamera)() = NULL;
uint64_t MPGameManager_Instance = 0;

// Hàm đọc an toàn
template <typename T> bool safe_read(uint64_t addr, T& out) {
    if (!addr) return false;
    vm_size_t size = 0;
    return vm_read_overwrite(mach_task_self(), addr, sizeof(T), (vm_address_t)&out, &size) == KERN_SUCCESS;
}
template <typename T> bool safe_write(uint64_t addr, const T& in) {
    if (!addr) return false;
    return vm_write(mach_task_self(), addr, (vm_address_t)&in, sizeof(T)) == KERN_SUCCESS;
}

// ================= TIMER QUÉT BỘ NHỚ & AIM =================
void HackLoop() {
    if (MPGameManager_Instance == 0 || !get_mainCamera) return;
    
    void* cam = get_mainCamera();
    if (!cam) return;

    // 1. Lấy vị trí Camera (LocalPlayer)
    Vector3 camPos = {0,0,0};
    uint64_t camTrans = 0;
    if (safe_read((uint64_t)cam + OFF_CAMERA_TRANS, camTrans) && camTrans) {
        safe_read(camTrans + OFF_POSITION, camPos);
    }

    // 2. Lấy danh sách địch
    uint64_t listPtr = 0;
    if (!safe_read(MPGameManager_Instance + OFF_OTHERPLAYERS, listPtr) || !listPtr) return;

    uint64_t arrayPtr = 0;
    int32_t length = 0;
    if (!safe_read(listPtr + 0x10, arrayPtr) || !safe_read(listPtr + 0x18, length)) return;
    if (length <= 0 || length > 64) return; // Chặn mảng lỗi

    float closestAngle = 150.0f;
    Vector3 bestTarget = {0,0,0};
    bool foundTarget = false;

    for (int i = 0; i < length; i++) {
        uint64_t trans = 0;
        if (!safe_read(arrayPtr + 0x20 + (i * 8), trans) || !trans) continue;

        Vector3 pos = {0,0,0};
        if (!safe_read(trans + OFF_POSITION, pos)) continue;

        Vector3 headPos = { pos.x, pos.y + 1.5f, pos.z };

        // Logic Aimbot
        if (isAimEnabled) {
            float dx = headPos.x - camPos.x;
            float dy = headPos.y - camPos.y;
            float dz = headPos.z - camPos.z;
            
            float targetYaw = atan2f(dx, dz) * 57.2958f;
            float targetPitch = atan2f(dy, sqrtf(dx*dx + dz*dz)) * 57.2958f;
            
            float curYaw = 0, curPitch = 0;
            safe_read((uint64_t)cam + OFF_YAW, curYaw);
            safe_read((uint64_t)cam + OFF_PITCH, curPitch);
            
            float yawDiff = targetYaw - curYaw;
            while (yawDiff > 180) yawDiff -= 360;
            while (yawDiff < -180) yawDiff += 360;
            
            float pitchDiff = fabsf(curPitch - targetPitch);
            float totalDiff = sqrtf(yawDiff*yawDiff + pitchDiff*pitchDiff);
            
            if (totalDiff < closestAngle) {
                closestAngle = totalDiff;
                bestTarget = headPos;
                foundTarget = true;
            }
        }
    }

    // 3. Ghi đè góc xoay Camera (Aim)
    if (foundTarget && isAimEnabled) {
        float dx = bestTarget.x - camPos.x;
        float dy = bestTarget.y - camPos.y;
        float dz = bestTarget.z - camPos.z;
        
        float targetYaw = atan2f(dx, dz) * 57.2958f;
        float targetPitch = atan2f(dy, sqrtf(dx*dx + dz*dz)) * 57.2958f;
        
        float curYaw = 0, curPitch = 0;
        safe_read((uint64_t)cam + OFF_YAW, curYaw);
        safe_read((uint64_t)cam + OFF_PITCH, curPitch);
        
        float yawDiff = targetYaw - curYaw;
        while (yawDiff > 180) yawDiff -= 360;
        while (yawDiff < -180) yawDiff += 360;
        
        float newYaw = curYaw + (yawDiff * aimSmooth);
        float newPitch = curPitch + ((targetPitch - curPitch) * aimSmooth);
        
        safe_write((uint64_t)cam + OFF_YAW, newYaw);
        safe_write((uint64_t)cam + OFF_PITCH, newPitch);
    }
}

// ================= HOOK LẤY INSTANCE (AN TOÀN) =================
// Chỉ hook hàm Start/Awake của MPGameManager, không hook Update/LateUpdate
typedef void (*Start_t)(void* self);
Start_t orig_Start = NULL;
void hook_Start(void* self) {
    orig_Start(self);
    MPGameManager_Instance = (uint64_t)self;
}

__attribute__((constructor))
static void init() {
    // Tạo Timer chạy 60fps trên Main Thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 target:[NSBlockOperation blockOperationWithBlock:^{
            HackLoop();
        }] selector:@selector(main) userInfo:nil repeats:YES];
    });
    
    // Quét hàm IL2CPP để lấy con trỏ
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        void* h = dlopen(NULL, RTLD_LAZY);
        if (!h) return;
        
        auto fn_dom = (void*(*)())dlsym(h, "il2cpp_domain_get");
        auto fn_asms = (void**(*)(void*, size_t*))dlsym(h, "il2cpp_domain_get_assemblies");
        auto fn_img = (void*(*)(void*))dlsym(h, "il2cpp_assembly_get_image");
        auto fn_c_count = (size_t(*)(void*))dlsym(h, "il2cpp_image_get_class_count");
        auto fn_c_get = (void*(*)(void*, size_t))dlsym(h, "il2cpp_image_get_class");
        auto fn_c_name = (const char*(*)(void*))dlsym(h, "il2cpp_class_get_name");
        auto fn_m_get = (void*(*)(void*, void**))dlsym(h, "il2cpp_class_get_methods");
        auto fn_m_name = (const char*(*)(void*))dlsym(h, "il2cpp_method_get_name");
        auto fn_m_ptr = (void*(*)(void*))dlsym(h, "il2cpp_method_get_pointer");

        if (!fn_dom) return;
        size_t count = 0;
        void** asms = fn_asms(fn_dom(), &count);
        
        for (size_t i = 0; i < count; i++) {
            void* img = fn_img(asms[i]);
            size_t clsCount = fn_c_count(img);
            for (size_t j = 0; j < clsCount; j++) {
                void* cls = fn_c_get(img, j);
                const char* cName = fn_c_name(cls);
                if (!cName) continue;

                // Hook Start của MPGameManager
                if (strcmp(cName, "MPGameManager") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = fn_m_get(cls, &iter))) {
                        const char* mName = fn_m_name(method);
                        if (mName && (strcmp(mName, "Start") == 0 || strcmp(mName, "Awake") == 0)) {
                            void* ptr = fn_m_ptr(method);
                            if (ptr && !orig_Start) {
                                MSHookFunction(ptr, (void*)hook_Start, (void**)&orig_Start);
                            }
                        }
                    }
                }
                // Lấy hàm Camera
                if (strcmp(cName, "Camera") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = fn_m_get(cls, &iter))) {
                        const char* mName = fn_m_name(method);
                        if (mName) {
                            if (strstr(mName, "WorldToScreenPoint")) {
                                WorldToScreenPoint = (void(*)(void*, Vector3, Vector3*))fn_m_ptr(method);
                            }
                            if (strstr(mName, "get_main")) {
                                get_mainCamera = (void*(*)())fn_m_ptr(method);
                            }
                        }
                    }
                }
            }
        }
    });
}
