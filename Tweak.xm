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

// Biến quản lý UI & Camera Instance toàn cục
static UIWindow *overlayWindow = nil;
static UIView *espDrawView = nil;
static CAShapeLayer *fovCircleLayer = nil;
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
// GIAO DIỆN MOD MENU NỔI (KÉO THẢ & THU GỌN THÔNG MINH)
// ==========================================
@interface ModMenuViewController : UIViewController
@property (nonatomic, strong) UIView *menuContainer;
@property (nonatomic, strong) UIButton *collapseBtn; // Menu bé (Nút HACK nổi)
@property (nonatomic, strong) UISwitch *switchAimHead;
@property (nonatomic, strong) UISwitch *switchAimBody;
@property (nonatomic, strong) UISwitch *switchEspBox;
@property (nonatomic, strong) UISwitch *switchEspLine;
@end

@implementation ModMenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.userInteractionEnabled = NO; // Mặc định nền trong suốt không chặn cảm ứng game
    
    // 1. Khung Menu To chính (Có thể kéo thả đi bất kỳ đâu)
    self.menuContainer = [[UIView alloc] initWithFrame:CGRectMake(40, 80, 240, 320)];
    self.menuContainer.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    self.menuContainer.layer.cornerRadius = 12.0f;
    self.menuContainer.layer.borderWidth = 1.5f;
    self.menuContainer.layer.borderColor = [UIColor redColor].CGColor;
    self.menuContainer.userInteractionEnabled = YES;
    self.menuContainer.hidden = NO;
    [self.view addSubview:self.menuContainer];
    
    // Thêm cử chỉ kéo thả (Pan Gesture) cho Menu To
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMenuPan:)];
    [self.menuContainer addGestureRecognizer:panGesture];
    
    // Tiêu đề Menu To
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 160, 30)];
    titleLabel.text = @"🔥 DudeHack Pro 🔥";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.menuContainer addSubview:titleLabel];
    
    // Nút thu nhỏ (Thu về Menu bé)
    UIButton *minimizeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    minimizeBtn.frame = CGRectMake(180, 10, 50, 30);
    [minimizeBtn setTitle:@"[ - ]" forState:UIControlStateNormal];
    [minimizeBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
    minimizeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [minimizeBtn addTarget:self action:@selector(minimizeMenu:) forControlEvents:UIControlEventTouchUpInside];
    [self.menuContainer addSubview:minimizeBtn];
    
    // Các hàng tính năng
    UIView *row1 = [self createRowWithFrame:CGRectMake(10, 50, 220, 30) title:@"Aim Đầu (Head)" action:@selector(toggleAimHead:) assignSwitch:&_switchAimHead];
    [self.menuContainer addSubview:row1];
    
    UIView *row2 = [self createRowWithFrame:CGRectMake(10, 90, 220, 30) title:@"Aim Thân (Body)" action:@selector(toggleAimBody:) assignSwitch:&_switchAimBody];
    [self.menuContainer addSubview:row2];
    
    UIView *row3 = [self createRowWithFrame:CGRectMake(10, 130, 220, 30) title:@"ESP Khung (Box)" action:@selector(toggleEspBox:) assignSwitch:&_switchEspBox];
    [self.menuContainer addSubview:row3];
    
    UIView *row4 = [self createRowWithFrame:CGRectMake(10, 170, 220, 30) title:@"ESP Đường (Line)" action:@selector(toggleEspLine:) assignSwitch:&_switchEspLine];
    [self.menuContainer addSubview:row4];
    
    // Slider FOV
    UILabel *fovLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 210, 220, 20)];
    fovLabel.text = @"Kích thước FOV";
    fovLabel.textColor = [UIColor lightGrayColor];
    fovLabel.font = [UIFont systemFontOfSize:12];
    [self.menuContainer addSubview:fovLabel];
    
    UISlider *fovSlider = [[UISlider alloc] initWithFrame:CGRectMake(10, 235, 220, 20)];
    fovSlider.minimumValue = 50.0f;
    fovSlider.maximumValue = 300.0f;
    fovSlider.value = g_fovRadius;
    [fovSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.menuContainer addSubview:fovSlider];
    
    // 2. Menu Bé (Nút HACK nổi tròn, kéo thả được và bấm để mở lại Menu To)
    self.collapseBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.collapseBtn.frame = CGRectMake(40, 40, 45, 45);
    self.collapseBtn.backgroundColor = [UIColor redColor];
    [self.collapseBtn setTitle:@"HACK" forState:UIControlStateNormal];
    [self.collapseBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.collapseBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    self.collapseBtn.layer.cornerRadius = 22.5f;
    self.collapseBtn.userInteractionEnabled = YES;
    self.collapseBtn.hidden = YES;
    [self.collapseBtn addTarget:self action:@selector(restoreMenu:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.collapseBtn];
    
    // Thêm cử chỉ kéo thả cho Menu Bé
    UIPanGestureRecognizer *panCollapse = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleCollapsePan:)];
    [self.collapseBtn addGestureRecognizer:panCollapse];
}

- (void)handleMenuPan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.view];
    UIView *menu = self.menuContainer;
    menu.center = CGPointMake(menu.center.x + translation.x, menu.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:self.view];
}

- (void)handleCollapsePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.view];
    UIButton *btn = self.collapseBtn;
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:self.view];
}

- (void)minimizeMenu:(UIButton *)sender {
    self.menuContainer.hidden = YES;
    self.collapseBtn.hidden = NO;
}

- (void)restoreMenu:(UIButton *)sender {
    self.collapseBtn.hidden = YES;
    self.menuContainer.hidden = NO;
}

- (UIView *)createRowWithFrame:(CGRect)frame title:(NSString *)title action:(SEL)action assignSwitch:(UISwitch *__strong *)targetSwitch {
    UIView *rowView = [[UIView alloc] initWithFrame:frame];
    rowView.userInteractionEnabled = YES;
    
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, frame.size.width - 60, frame.size.height)];
    lbl.text = title;
    lbl.textColor = [UIColor whiteColor];
    lbl.font = [UIFont systemFontOfSize:13];
    [rowView addSubview:lbl];
    
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(frame.size.width - 55, (frame.size.height - 30)/2, 50, 30)];
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [rowView addSubview:sw];
    
    if (targetSwitch) {
        *targetSwitch = sw;
    }
    return rowView;
}

- (void)toggleAimHead:(UISwitch *)sender {
    g_aimHeadEnabled = sender.isOn;
    if (g_aimHeadEnabled) {
        g_aimBodyEnabled = NO;
        if (self.switchAimBody) self.switchAimBody.on = NO;
    }
}

- (void)toggleAimBody:(UISwitch *)sender {
    g_aimBodyEnabled = sender.isOn;
    if (g_aimBodyEnabled) {
        g_aimHeadEnabled = NO;
        if (self.switchAimHead) self.switchAimHead.on = NO;
    }
}

- (void)toggleEspBox:(UISwitch *)sender {
    g_espBoxEnabled = sender.isOn;
}

- (void)toggleEspLine:(UISwitch *)sender {
    g_espLineEnabled = sender.isOn;
}

- (void)sliderChanged:(UISlider *)sender {
    g_fovRadius = sender.value;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (fovCircleLayer && overlayWindow) {
            CGRect screenBounds = overlayWindow.bounds;
            UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(screenBounds.size.width/2, screenBounds.size.height/2)
                                                              radius:g_fovRadius
                                                          startAngle:0
                                                            endAngle:2 * M_PI
                                                           clockwise:YES];
            fovCircleLayer.path = path.CGPath;
        }
    });
}

@end

// ==========================================
// KHỞI TẠO CỬA SỔ NỔI & GIAO DIỆN ESP
// ==========================================
static void setupOverlayWindow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (overlayWindow) return;
        
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        overlayWindow = [[UIWindow alloc] initWithFrame:screenBounds];
        overlayWindow.windowLevel = UIWindowLevelAlert + 100;
        overlayWindow.backgroundColor = [UIColor clearColor];
        overlayWindow.userInteractionEnabled = NO; // Cho phép chạm xuyên thấu game toàn cục
        
        ModMenuViewController *menuVC = [[ModMenuViewController alloc] init];
        overlayWindow.rootViewController = menuVC;
        menuVC.view.userInteractionEnabled = YES;
        
        espDrawView = [[UIView alloc] initWithFrame:screenBounds];
        espDrawView.backgroundColor = [UIColor clearColor];
        espDrawView.userInteractionEnabled = NO;
        [menuVC.view addSubview:espDrawView];
        [menuVC.view sendSubviewToBack:espDrawView];
        
        fovCircleLayer = [CAShapeLayer layer];
        UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(screenBounds.size.width/2, screenBounds.size.height/2)
                                                          radius:g_fovRadius
                                                      startAngle:0
                                                        endAngle:2 * M_PI
                                                       clockwise:YES];
        fovCircleLayer.path = path.CGPath;
        fovCircleLayer.fillColor = [UIColor clearColor].CGColor;
        fovCircleLayer.strokeColor = [UIColor redColor].CGColor;
        fovCircleLayer.lineWidth = 1.2f;
        [espDrawView.layer addSublayer:fovCircleLayer];
        
        overlayWindow.hidden = NO;
        NSLog(@"[DudeHack] Đã khởi tạo thành công hệ thống kéo thả và cảm ứng thông minh!");
    });
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
        setupOverlayWindow();
    });
}
