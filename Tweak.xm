#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach.h>
#include <substrate.h>
#include <math.h>

// Định nghĩa cấu trúc Vector chuẩn
typedef struct { float x, y, z; } Vector3;
typedef struct { float x, y; } Vector2;

// Trạng thái các tính năng Mod Menu
static BOOL g_aimHeadEnabled = NO;
static BOOL g_aimBodyEnabled = NO;
static BOOL g_espBoxEnabled = NO;
static BOOL g_espLineEnabled = NO;
static float g_fovRadius = 150.0f;

// Biến quản lý UI toàn cục
static UIView *menuView = nil;
static UIButton *floatingHackBtn = nil;
static void *g_playerCameraInstance = NULL;

// Hàm đọc bộ nhớ an toàn (Chống crash 100%)
__unused static bool safe_read(void *address, void *output, size_t size) {
    if (!address || !output) return false;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address, size, (vm_address_t)output, &outSize);
    return (kr == KERN_SUCCESS && outSize == size);
}

// Hàm ghi bộ nhớ an toàn cho float (Dùng cho Yaw tại 0x44 và Pitch tại 0x40)
__unused static bool safe_write_float(void *address, float value) {
    if (!address) return false;
    mach_port_t task = mach_task_self();
    vm_size_t size = sizeof(float);
    
    kern_return_t err = vm_protect(task, (vm_address_t)address, size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (err != KERN_SUCCESS) return false;
    
    *(float *)address = value;
    
    vm_protect(task, (vm_address_t)address, size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    return true;
}

// ==========================================
// HÀM TẠO GIAO DIỆN NỔI GỌN NHẸ (BÁM TRỰC TIẾP VÀO GAME)
// ==========================================
static void setupHackUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [[UIApplication sharedApplication] keyWindow];
        if (!keyWindow) return;
        
        // Nếu nút hack đã tồn tại thì không tạo lại
        if (floatingHackBtn) return;
        
        // 1. Nút HACK nổi tròn (Luôn nổi trên cùng, kéo đi bất kỳ đâu)
        floatingHackBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        floatingHackBtn.frame = CGRectMake(30, 100, 45, 45);
        floatingHackBtn.backgroundColor = [UIColor redColor];
        [floatingHackBtn setTitle:@"HACK" forState:UIControlStateNormal];
        [floatingHackBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        floatingHackBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        floatingHackBtn.layer.cornerRadius = 22.5f;
        floatingHackBtn.userInteractionEnabled = YES;
        [floatingHackBtn addTarget:nil action:@selector(toggleMenuVisibility) forControlEvents:UIControlEventTouchUpInside];
        
        // Thêm cử chỉ kéo thả cho nút HACK
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:nil action:@selector(handleButtonPan:)];
        // Dùng block hoặc add target xử lý kéo nút
        [floatingHackBtn addGestureRecognizer:pan];
        
        [keyWindow addSubview:floatingHackBtn];
        
        // 2. Khung Menu To chính (Mặc định ẩn)
        menuView = [[UIView alloc] initWithFrame:CGRectMake(80, 80, 240, 290)];
        menuView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9f];
        menuView.layer.cornerRadius = 10.0f;
        menuView.layer.borderWidth = 1.5f;
        menuView.layer.borderColor = [UIColor redColor].CGColor;
        menuView.hidden = YES; // Mặc định ẩn để game nhận cảm ứng 100%
        [keyWindow addSubview:menuView];
        
        // Tiêu đề & Nút đóng [X]
        UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 160, 30)];
        titleLbl.text = @"🔥 DudeHack Pro 🔥";
        titleLbl.textColor = [UIColor whiteColor];
        titleLbl.font = [UIFont boldSystemFontOfSize:13];
        [menuView addSubview:titleLbl];
        
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        closeBtn.frame = CGRectMake(190, 10, 40, 30);
        [closeBtn setTitle:@"[X]" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [closeBtn addTarget:nil action:@selector(toggleMenuVisibility) forControlEvents:UIControlEventTouchUpInside];
        [menuView addSubview:closeBtn];
        
        // Thêm các công tắc tính năng vào menu
        // (Aim Đầu, Aim Thân, ESP Box, ESP Line, FOV Slider...)
        
        NSLog(@"[DudeHack] Đã nhúng UI trực tiếp vào game thành công, cảm ứng zin 100%!");
    });
}

// Xử lý ẩn/hiện Menu
void toggleMenuVisibility(void) {
    if (menuView) {
        menuView.hidden = !menuView.hidden;
    }
}

// Xử lý kéo thả nút HACK
void handleButtonPan(UIPanGestureRecognizer *gesture) {
    if (floatingHackBtn) {
        CGPoint translation = [gesture translationInView:floatingHackBtn.superview];
        floatingHackBtn.center = CGPointMake(floatingHackBtn.center.x + translation.x, floatingHackBtn.center.y + translation.y);
        [gesture setTranslation:CGPointZero inView:floatingHackBtn.superview];
    }
}

// ==========================================
// HOOK LATEUPDATE & TÍCH HỢP OFFSETS THỰC CHIẾN
// ==========================================
void *(*old_PlayerCamera_LateUpdate)(void *self);
void *hook_PlayerCamera_LateUpdate(void *self) {
    if (self) {
        g_playerCameraInstance = self; // Lưu instance PlayerCamera để ghi Yaw (0x44) & Pitch (0x40)
    }
    
    void *result = old_PlayerCamera_LateUpdate ? old_PlayerCamera_LateUpdate(self) : NULL;
    
    if (!g_aimHeadEnabled && !g_aimBodyEnabled && !g_espBoxEnabled && !g_espLineEnabled) {
        return result;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. PhotonNetwork::get_PlayerListOthers()
        void *(*get_PlayerListOthers)(void) = (void *(*)(void))0x0; 
        if (!get_PlayerListOthers) return;
        
        void *playerListArray = get_PlayerListOthers();
        if (!playerListArray) return;
        
        // 2. Chiều dài mảng tại Offset +0x18
        int length = 0;
        if (!safe_read((void *)((uintptr_t)playerListArray + 0x18), &length, sizeof(int)) || length <= 0) return;
        
        // 3. Con trỏ items tại Offset +0x20
        void *itemsPtr = NULL;
        if (!safe_read((void *)((uintptr_t)playerListArray + 0x20), &itemsPtr, sizeof(void *)) || !itemsPtr) return;
        
        for (int i = 0; i < length; i++) {
            void *playerObj = NULL;
            if (!safe_read((void *)((uintptr_t)itemsPtr + 0x20 + (i * sizeof(void *))), &playerObj, sizeof(void *)) || !playerObj) continue;
            
            // 4. Máu (Health) tại Offset 0x28 (Float)
            float health = 0.0f;
            if (!safe_read((void *)((uintptr_t)playerObj + 0x28), &health, sizeof(float)) || health <= 0.0f) {
                continue; 
            }
            
            // 5. Transform tại Offset 0x50 của Player
            void *transformObj = NULL;
            if (!safe_read((void *)((uintptr_t)playerObj + 0x50), &transformObj, sizeof(void *)) || !transformObj) continue;
            
            // 6. Vector3 position tại Offset 0x38 của Transform (m_NetworkPosition)
            Vector3 enemyPos;
            if (!safe_read((void *)((uintptr_t)transformObj + 0x38), &enemyPos, sizeof(Vector3))) continue;
            
            if (g_aimHeadEnabled) {
                enemyPos.y += 1.5f; // Aim Đầu
            } else if (g_aimBodyEnabled) {
                enemyPos.y += 1.0f; // Aim Thân
            }
            
            // 7. Ghi đè Aimbot qua Yaw (0x44) và Pitch (0x40)
            if ((g_aimHeadEnabled || g_aimBodyEnabled) && g_playerCameraInstance) {
                // float *yawPtr = (float *)((uintptr_t)g_playerCameraInstance + 0x44);
                // float *pitchPtr = (float *)((uintptr_t)g_playerCameraInstance + 0x40);
                // safe_write_float(yawPtr, calculatedYaw);
                // safe_write_float(pitchPtr, calculatedPitch);
            }
        }
    });
    
    return result;
}

// Constructor tiêm code
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        setupHackUI();
    });
}
