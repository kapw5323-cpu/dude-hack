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

// ================= CẤU HÌNH =================
#define OFF_PLAYER_AVATAR  0x40
#define OFF_OTHERPLAYERS   0x70
#define OFF_AVATAR_TRANS   0x90
#define OFF_YAW            0x68
#define OFF_PITCH          0x64
#define OFF_POSITION       0x38

bool isEspBox = true;
bool isEspLine = true;
bool isAimEnabled = true; 
float fovRadius = 150.0f;
float aimSmooth = 0.35f;

struct Vector3 { float x, y, z; };
std::vector<Vector3> enemyPositions;
os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;

// Con trỏ hàm
void* (*il2cpp_domain_get)();
void** (*il2cpp_domain_get_assemblies)(void*, size_t*);
void* (*il2cpp_assembly_get_image)(void*);
size_t (*il2cpp_image_get_class_count)(void*);
void* (*il2cpp_image_get_class)(void*, size_t);
const char* (*il2cpp_class_get_name)(void*);
void* (*il2cpp_class_get_methods)(void*, void**);
const char* (*il2cpp_method_get_name)(void*);
void* (*il2cpp_method_get_pointer)(void*);

// Chú ý: WorldToScreenPoint trả về struct qua con trỏ (Vector3* ret)
void (*WorldToScreenPoint)(void* cam, Vector3 pos, Vector3* ret) = NULL;
void* (*get_mainCamera)() = NULL;

uint64_t MPGameManager_Instance = 0;

// Hàm đọc/ghi an toàn (Bọc thép chống crash)
template <typename T> bool safe_read(uint64_t addr, T& out) {
    if (!addr) return false;
    vm_size_t size = 0;
    return vm_read_overwrite(mach_task_self(), addr, sizeof(T), (vm_address_t)&out, &size) == KERN_SUCCESS;
}
template <typename T> bool safe_write(uint64_t addr, const T& in) {
    if (!addr) return false;
    return vm_write(mach_task_self(), addr, (vm_address_t)&in, sizeof(T)) == KERN_SUCCESS;
}

// ================= GIAO DIỆN =================
@interface ESPOverlay : UIView
@end
@implementation ESPOverlay
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextClearRect(ctx, self.bounds);
    
    CGContextSetStrokeColorWithColor(ctx, [UIColor redColor].CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(self.bounds.size.width/2 - fovRadius, self.bounds.size.height/2 - fovRadius, fovRadius*2, fovRadius*2));

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
            if (isEspBox) {
                CGContextStrokeRect(ctx, CGRectMake(screen.x - 30, screen.y - 60, 60, 120));
            }
            if (isEspLine) {
                CGContextMoveToPoint(ctx, self.bounds.size.width/2, self.bounds.size.height);
                CGContextAddLineToPoint(ctx, screen.x, screen.y + 60);
                CGContextStrokePath(ctx);
            }
        }
    }
    os_unfair_lock_unlock(&lock);
}
@end
ESPOverlay *espView = nil;

// ================= LOGIC CỐT LÕI =================
typedef void (*CameraUpdate_t)(void* self);
CameraUpdate_t orig_CameraUpdate = NULL;

void hook_CameraUpdate(void* self) {
    orig_CameraUpdate(self);
    
    // Nếu chưa tìm thấy MPGameManager thì bỏ qua (tránh crash)
    if (MPGameManager_Instance == 0) return;

    Vector3 camPos = {0,0,0};
    uint64_t camTrans = 0;
    if (safe_read((uint64_t)self + OFF_CAMERA_TRANS, camTrans) && camTrans) {
        safe_read(camTrans + OFF_POSITION, camPos);
    }

    os_unfair_lock_lock(&lock);
    enemyPositions.clear();
    os_unfair_lock_unlock(&lock);

    uint64_t listPtr = 0;
    if (safe_read(MPGameManager_Instance + OFF_OTHERPLAYERS, listPtr) && listPtr) {
        uint64_t arrayPtr = 0;
        int32_t length = 0;
        
        if (safe_read(listPtr + 0x10, arrayPtr) && safe_read(listPtr + 0x18, length) && length > 0 && length < 64) {
            float closestAngle = fovRadius;
            Vector3 bestTarget = {0,0,0};
            bool foundTarget = false;

            for (int i = 0; i < length; i++) {
                uint64_t trans = 0;
                if (safe_read(arrayPtr + 0x20 + (i * 8), trans) && trans) {
                    Vector3 pos = {0,0,0};
                    if (safe_read(trans + OFF_POSITION, pos)) {
                        // Tọa độ đầu để vẽ Box
                        Vector3 headPos = { pos.x, pos.y + 1.5f, pos.z }; 
                        
                        os_unfair_lock_lock(&lock);
                        enemyPositions.push_back(headPos);
                        os_unfair_lock_unlock(&lock);
                        
                        // Logic Aimbot
                        if (isAimEnabled) {
                            float dx = headPos.x - camPos.x;
                            float dy = headPos.y - camPos.y;
                            float dz = headPos.z - camPos.z;
                            
                            float targetYaw = atan2f(dx, dz) * 57.2958f;
                            float targetPitch = atan2f(dy, sqrtf(dx*dx + dz*dz)) * 57.2958f;
                            
                            float curYaw = 0, curPitch = 0;
                            safe_read((uint64_t)self + OFF_YAW, curYaw);
                            safe_read((uint64_t)self + OFF_PITCH, curPitch);
                            
                            // Tính góc lệch ngắn nhất (tránh xoay 360 độ)
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
                }
            }
            
            // Kéo tâm mượt
            if (foundTarget && isAimEnabled) {
                float dx = bestTarget.x - camPos.x;
                float dy = bestTarget.y - camPos.y;
                float dz = bestTarget.z - camPos.z;
                
                float targetYaw = atan2f(dx, dz) * 57.2958f;
                float targetPitch = atan2f(dy, sqrtf(dx*dx + dz*dz)) * 57.2958f;
                
                float curYaw = 0, curPitch = 0;
                safe_read((uint64_t)self + OFF_YAW, curYaw);
                safe_read((uint64_t)self + OFF_PITCH, curPitch);
                
                float yawDiff = targetYaw - curYaw;
                while (yawDiff > 180) yawDiff -= 360;
                while (yawDiff < -180) yawDiff += 360;
                
                float newYaw = curYaw + (yawDiff * aimSmooth);
                float newPitch = curPitch + ((targetPitch - curPitch) * aimSmooth);
                
                safe_write((uint64_t)self + OFF_YAW, newYaw);
                safe_write((uint64_t)self + OFF_PITCH, newPitch);
            }
        }
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (espView) [espView setNeedsDisplay];
    });
}

// ================= HOOK LẤY INSTANCE =================
typedef void (*MPGameManager_Update_t)(void* self);
MPGameManager_Update_t orig_MPGameManager_Update = NULL;
void hook_MPGameManager_Update(void* self) {
    orig_MPGameManager_Update(self);
    MPGameManager_Instance = (uint64_t)self; // Lấy instance liên tục, đảm bảo an toàn
}

// ================= KHỞI TẠO =================
__attribute__((constructor))
static void init() {
    dispatch_async(dispatch_get_main_queue(), ^{
        espView = [[ESPOverlay alloc] initWithFrame:[UIScreen mainScreen].bounds];
        espView.backgroundColor = [UIColor clearColor];
        espView.userInteractionEnabled = NO;
        [[UIApplication sharedApplication].keyWindow addSubview:espView];
    });
    
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
                
                if (strcmp(clsName, "MPGameManager") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = il2cpp_class_get_methods(cls, &iter))) {
                        const char* mName = il2cpp_method_get_name(method);
                        if (mName && strcmp(mName, "Update") == 0) {
                            void* ptr = il2cpp_method_get_pointer(method);
                            if (ptr && !orig_MPGameManager_Update) {
                                MSHookFunction(ptr, (void*)hook_MPGameManager_Update, (void**)&orig_MPGameManager_Update);
                            }
                        }
                    }
                }
                if (strcmp(clsName, "Camera") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = il2cpp_class_get_methods(cls, &iter))) {
                        const char* mName = il2cpp_method_get_name(method);
                        if (mName && strstr(mName, "WorldToScreenPoint")) {
                            WorldToScreenPoint = (void(*)(void*, Vector3, Vector3*))il2cpp_method_get_pointer(method);
                        }
                        if (mName && strstr(mName, "get_main")) {
                            get_mainCamera = (void*(*)())il2cpp_method_get_pointer(method);
                        }
                    }
                }
                if (strcmp(clsName, "CameraControl") == 0) {
                    void* iter = NULL; void* method;
                    while ((method = il2cpp_class_get_methods(cls, &iter))) {
                        const char* mName = il2cpp_method_get_name(method);
                        if (mName && strstr(mName, "LateUpdate")) {
                            void* ptr = il2cpp_method_get_pointer(method);
                            if (ptr && !orig_CameraUpdate) {
                                MSHookFunction(ptr, (void*)hook_CameraUpdate, (void**)&orig_CameraUpdate);
                            }
                        }
                    }
                }
            }
        }
    });
}
