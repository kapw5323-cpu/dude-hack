#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <cmath>
#include <string.h>
#include <vector>
#include <os/lock.h>

// --- OFFSET CHUẨN ---
#define OFF_OTHERPLAYERS   0x70
#define OFF_CAMERA_TRANS   0x20
#define OFF_YAW            0x68
#define OFF_PITCH          0x64
#define OFF_POSITION       0x38

bool isAimEnabled = true; 
float aimSmooth = 0.35f;

struct Vector3 { float x, y, z; };
std::vector<Vector3> enemyPositions;
os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;

// Hàm game
void (*WorldToScreenPoint)(void* cam, Vector3 pos, Vector3* ret) = NULL;
void* (*get_mainCamera)() = NULL;

uint64_t MPGameManager_Instance = 0;
uint64_t CameraControl_Instance = 0;

template <typename T> bool safe_read(uint64_t addr, T& out) {
    if (!addr) return false;
    vm_size_t size = 0;
    return vm_read_overwrite(mach_task_self(), addr, sizeof(T), (vm_address_t)&out, &size) == KERN_SUCCESS;
}
template <typename T> bool safe_write(uint64_t addr, const T& in) {
    if (!addr) return false;
    return vm_write(mach_task_self(), addr, (vm_address_t)&in, sizeof(T)) == KERN_SUCCESS;
}

// Hàm kiểm tra tọa độ hợp lệ (Chống crash do dữ liệu rác)
bool isValidPos(Vector3 pos) {
    if (isnan(pos.x) || isnan(pos.y) || isnan(pos.z)) return false;
    if (isinf(pos.x) || isinf(pos.y) || isinf(pos.z)) return false;
    if (pos.x == 0 && pos.y == 0 && pos.z == 0) return false; // Tọa độ gốc (thường là rác)
    return true;
}

// ================= GIAO DIỆN VẼ =================
@interface ESPOverlay : UIView
@end
@implementation ESPOverlay
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextClearRect(ctx, self.bounds);
    if (!get_mainCamera || !WorldToScreenPoint) return;
    void* cam = get_mainCamera();
    if (!cam) return;

    os_unfair_lock_lock(&lock);
    for (auto& pos : enemyPositions) {
        Vector3 screen = {0,0,0};
        WorldToScreenPoint(cam, pos, &screen);
        if (screen.x > 0 && screen.x < self.bounds.size.width && screen.y > 0 && screen.y < self.bounds.size.height) {
            CGContextSetStrokeColorWithColor(ctx, [UIColor redColor].CGColor);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextStrokeRect(ctx, CGRectMake(screen.x - 30, screen.y - 60, 60, 120));
        }
    }
    os_unfair_lock_unlock(&lock);
}
@end
ESPOverlay *espView = nil;

// ================= LOGIC CHÍNH =================
dispatch_source_t timer = NULL;

void HackLoop() {
    if (MPGameManager_Instance == 0 || CameraControl_Instance == 0) return;

    // 1. Lấy vị trí Camera an toàn
    Vector3 camPos = {0,0,0};
    uint64_t camTrans = 0;
    if (safe_read(CameraControl_Instance + OFF_CAMERA_TRANS, camTrans) && camTrans) {
        safe_read(camTrans + OFF_POSITION, camPos);
    }

    float curYaw = 0, curPitch = 0;
    safe_read(CameraControl_Instance + OFF_YAW, curYaw);
    safe_read(CameraControl_Instance + OFF_PITCH, curPitch);

    // 2. Đọc List an toàn (Snapshot)
    uint64_t listPtr = 0;
    if (!safe_read(MPGameManager_Instance + OFF_OTHERPLAYERS, listPtr) || !listPtr) return;

    uint64_t arrayPtr = 0;
    int32_t length = 0;
    if (!safe_read(listPtr + 0x10, arrayPtr) || !safe_read(listPtr + 0x18, length)) return;
    if (length <= 0 || length > 64) return; // Chặn mảng lỗi

    os_unfair_lock_lock(&lock);
    enemyPositions.clear();
    os_unfair_lock_unlock(&lock);

    float closestAngle = 150.0f;
    Vector3 bestTarget = {0,0,0};
    bool foundTarget = false;

    for (int i = 0; i < length; i++) {
        uint64_t trans = 0;
        if (!safe_read(arrayPtr + 0x20 + (i * 8), trans) || !trans) continue;
        
        // Đọc tọa độ với kiểm tra an toàn
        Vector3 pos = {0,0,0};
        if (!safe_read(trans + OFF_POSITION, pos)) continue;
        
        // NẾU TỌA ĐỘ LÀ RÁC -> BỎ QUA (Đây là chốt chặn sinh tử)
        if (!isValidPos(pos)) continue; 

        Vector3 headPos = { pos.x, pos.y + 1.5f, pos.z };
        os_unfair_lock_lock(&lock);
        enemyPositions.push_back(headPos);
        os_unfair_lock_unlock(&lock);

        if (isAimEnabled) {
            float dx = headPos.x - camPos.x;
            float dy = headPos.y - camPos.y;
            float dz = headPos.z - camPos.z;
            
            float targetYaw = atan2f(dx, dz) * 57.2958f;
            float targetPitch = atan2f(dy, sqrtf(dx*dx + dz*dz)) * 57.2958f;
            
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

    // 3. Kéo tâm
    if (foundTarget && isAimEnabled) {
        float dx = bestTarget.x - camPos.x;
        float dy = bestTarget.y - camPos.y;
        float dz = bestTarget.z - camPos.z;
        
        float targetYaw = atan2f(dx, dz) * 57.2958f;
        float targetPitch = atan2f(dy, sqrtf(dx*dx + dz*dz)) * 57.2958f;
        
        float yawDiff = targetYaw - curYaw;
        while (yawDiff > 180) yawDiff -= 360;
        while (yawDiff < -180) yawDiff += 360;
        
        float newYaw = curYaw + (yawDiff * aimSmooth);
        float newPitch = curPitch + ((targetPitch - curPitch) * aimSmooth);
        
        safe_write(CameraControl_Instance + OFF_YAW, newYaw);
        safe_write(CameraControl_Instance + OFF_PITCH, newPitch);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (espView) [espView setNeedsDisplay];
    });
}

// ================= HOOK =================
typedef void (*MPGameManager_Update_t)(void* self);
MPGameManager_Update_t orig_MPGameManager_Update = NULL;
void hook_MPGameManager_Update(void* self) {
    orig_MPGameManager_Update(self);
    MPGameManager_Instance = (uint64_t)self;
}

typedef void (*CameraControl_Update_t)(void* self);
CameraControl_Update_t orig_CameraControl_Update = NULL;
void hook_CameraControl_Update(void* self) {
    orig_CameraControl_Update(self);
    CameraControl_Instance = (uint64_t)self;
}

__attribute__((constructor))
static void init() {
    dispatch_async(dispatch_get_main_queue(), ^{
        espView = [[ESPOverlay alloc] initWithFrame:[UIScreen mainScreen].bounds];
        espView.backgroundColor = [UIColor clearColor];
        espView.userInteractionEnabled = NO;
        [[UIApplication sharedApplication].windows.firstObject addSubview:espView];

        // Dispatch Timer (Cực nhẹ, không rò rỉ bộ nhớ)
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60.0, 0);
        dispatch_source_set_event_handler(timer, ^{ HackLoop(); });
        dispatch_resume(timer);
    });
    
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

                if (strcmp(cName, "MPGameManager") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = fn_m_get(cls, &iter))) {
                        const char* mName = fn_m_name(method);
                        if (mName && strcmp(mName, "Update") == 0) {
                            void* ptr = fn_m_ptr(method);
                            if (ptr && !orig_MPGameManager_Update) MSHookFunction(ptr, (void*)hook_MPGameManager_Update, (void**)&orig_MPGameManager_Update);
                        }
                    }
                }
                if (strcmp(cName, "CameraControl") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = fn_m_get(cls, &iter))) {
                        const char* mName = fn_m_name(method);
                        if (mName && strstr(mName, "Update")) {
                            void* ptr = fn_m_ptr(method);
                            if (ptr && !orig_CameraControl_Update) MSHookFunction(ptr, (void*)hook_CameraControl_Update, (void**)&orig_CameraControl_Update);
                        }
                    }
                }
                if (strcmp(cName, "Camera") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = fn_m_get(cls, &iter))) {
                        const char* mName = fn_m_name(method);
                        if (mName) {
                            if (strstr(mName, "WorldToScreenPoint")) WorldToScreenPoint = (void(*)(void*, Vector3, Vector3*))fn_m_ptr(method);
                            if (strstr(mName, "get_main")) get_mainCamera = (void*(*)())fn_m_ptr(method);
                        }
                    }
                }
            }
        }
    });
}
