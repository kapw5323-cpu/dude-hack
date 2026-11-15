#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach.h>
#include <substrate.h>

// Định nghĩa cấu trúc Vector cơ bản
typedef struct { float x, y, z; } Vector3;
typedef struct { float x, y; } Vector2;

// Trạng thái các tính năng Mod Menu (Mặc định tắt toàn bộ để đảm bảo an toàn)
static BOOL g_aimHeadEnabled = NO;
static BOOL g_aimBodyEnabled = NO;
static BOOL g_espBoxEnabled = NO;
static BOOL g_espLineEnabled = NO;
static float g_fovRadius = 150.0f; // Bán kính vòng FOV mặc định

// Biến quản lý UI toàn cục
static UIWindow *overlayWindow = nil;
static UIView *espDrawView = nil;
static CAShapeLayer *fovCircleLayer = nil;

// Lưu trữ instance của PlayerCamera để phục vụ việc ghi đè góc nhìn (Aimbot)
static void *g_playerCameraInstance = NULL;

// Hàm đọc bộ nhớ an toàn tuyệt đối qua vm_read_overwrite
template <typename T>
bool safe_read(void *address, T &output) {
    if (!address) return false;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address, sizeof(T), (vm_address_t)&output, &outSize);
    return (kr == KERN_SUCCESS && outSize == sizeof(T));
}

// Hàm ghi bộ nhớ an toàn (bypass bảo vệ trang bộ nhớ để tránh Crash app khi ghi đè Camera Yaw/Pitch)
bool safe_write_float(void *address, float value) {
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
// GIAO DIỆN MOD MENU NỔI (FLOATING UI MENU)
// ==========================================
@interface ModMenuViewController : UIViewController
@property (nonatomic, strong) UIView *menuContainer;
@property (nonatomic, strong) UISwitch *switchAimHead;
@property (nonatomic, strong) UISwitch *switchAimBody;
@property (nonatomic, strong) UISwitch *switchEspBox;
@property (nonatomic, strong) UISwitch *switchEspLine;
@end

@implementation ModMenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    
    // Khung Menu chính
    self.menuContainer = [[UIView alloc] initWithFrame:CGRectMake(20, 80, 240, 310)];
    self.menuContainer.backgroundColor = [[UIColor blackColor] colorWithAlphaCoordinate:0.85];
    self.menuContainer.layer.cornerRadius = 12.0f;
    self.menuContainer.layer.borderWidth = 1.5f;
    self.menuContainer.layer.borderColor = [UIColor redColor].CGColor;
    self.menuContainer.userInteractionEnabled = YES;
    [self.view addSubview:self.menuContainer];
    
    // Tiêu đề Menu
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 220, 30)];
    titleLabel.text = @"🔥 DudeHack Menu 🔥";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:15];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.menuContainer addSubview:titleLabel];
    
    // Thêm các hàng chức năng (Label + Switch)
    [self addMenuRow:CGRectMake(10, 50, 220, 30) title:@"Aim Đầu (Head)" action:@selector(toggleAimHead:) isSwitch:&_switchAimHead];
    [self addMenuRow:CGRectMake(10, 90, 220, 30) title:@"Aim Thân (Body)" action:@selector(toggleAimBody:) isSwitch:&_switchAimBody];
    [self addMenuRow:CGRectMake(10, 130, 220, 30) title:@"ESP Box" action:@selector(toggleEspBox:) isSwitch:&_switchEspBox];
    [self addMenuRow:CGRectMake(10, 170, 220, 30) title:@"ESP Line" action:@selector(toggleEspLine:) actionTarget:self]; // Hoặc cách tương tự
    
    // Slider chỉnh kích thước FOV
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
    
    // Nút thu nhỏ/mở rộng Menu nhanh
    UIButton *collapseBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    collapseBtn.frame = CGRectMake(20, 40, 45, 45);
    collapseBtn.backgroundColor = [UIColor redColor];
    [collapseBtn setTitle:@"HACK" forState:UIControlStateNormal];
    [collapseBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    collapseBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    collapseBtn.layer.cornerRadius = 22.5f;
    [collapseBtn addTarget:self action:@selector(toggleMenu:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:collapseBtn];
}

- (void)addMenuRow:(CGRect)frame title:(NSString *)title action:(SEL)action isSwitch:(UISwitch **)outSwitch {
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, frame.size.width - 60, frame.size.height)];
    lbl.text = title;
    lbl.textColor = [UIColor whiteColor];
    lbl.font = [UIFont systemFontOfSize:13];
    
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(frame.size.width - 55, (frame.size.height - 30)/2, 50, 30)];
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    
    UIView *rowView = [[UIView alloc] initWithFrame:frame];
    [rowView addSubview:lbl];
    [rowView addSubview:sw];
    [self.menuContainer addSubview:rowView];
    
    if (outSwitch) *outSwitch = sw;
}

// Bổ sung overload phụ cho ESP Line
- (void)addMenuRow:(CGRect)frame title:(NSString *)title action:(SEL)action actionTarget:(id)target {
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, frame.size.width - 60, frame.size.height)];
    lbl.text = title;
    lbl.textColor = [UIColor whiteColor];
    lbl.font = [UIFont systemFontOfSize:13];
    
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(frame.size.width - 55, (frame.size.height - 30)/2, 50, 30)];
    [sw addTarget:self action:@selector(toggleEspLine:) forControlEvents:UIControlEventValueChanged];
    
    UIView *rowView = [[UIView alloc] initWithFrame:frame];
    [rowView addSubview:lbl];
    [rowView addSubview:sw];
    [self.menuContainer addSubview:rowView];
}

// --- LOGIC QUẢN LÝ NÚT BẤM (LOẠI TRỪ LẪN NHAU GIỮA AIM ĐẦU VÀ AIM THÂN) ---
- (void)toggleAimHead:(UISwitch *)sender {
    g_aimHeadEnabled = sender.isOn;
    if (g_aimHeadEnabled) {
        g_aimBodyEnabled = NO;
        if (self.switchAimBody) self.switchAimBody.on = NO; // Tắt Aim Thân ngay lập tức
    }
}

- (void)toggleAimBody:(UISwitch *)sender {
    g_aimBodyEnabled = sender.isOn;
    if (g_aimBodyEnabled) {
        g_aimHeadEnabled = NO;
        if (self.switchAimHead) self.switchAimHead.on = NO; // Tắt Aim Đầu ngay lập tức
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
    // Cập nhật lại kích thước vòng FOV ngay lập tức trên Main Thread
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

- (void)toggleMenu:(UIButton *)sender {
    self.menuContainer.hidden = !self.menuContainer.hidden;
}

@end

// ==========================================
// KHỞI TẠO CỬA SỔ NỔI BẤT TỬ
// ==========================================
static void setupOverlayWindow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (overlayWindow) return;
        
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        overlayWindow = [[UIWindow alloc] initWithFrame:screenBounds];
        overlayWindow.windowLevel = UIWindowLevelAlert + 100;
        overlayWindow.backgroundColor = [UIColor clearColor];
        overlayWindow.userInteractionEnabled = YES; // Cho phép tương tác chạm vào Menu
        
        ModMenuViewController *menuVC = [[ModMenuViewController alloc] init];
        overlayWindow.rootViewController = menuVC;
        
        // Thêm Layer chuyên dụng vẽ ESP Box/Line và FOV nằm ở dưới UI Menu để không cản trở việc bấm nút
        espDrawView = [[UIView alloc] initWithFrame:screenBounds];
        espDrawView.backgroundColor = [UIColor clearColor];
        espDrawView.userInteractionEnabled = NO;
        [menuVC.view addSubview:espDrawView];
        [menuVC.view sendSubviewToBack:espDrawView];
        
        // Vẽ vòng FOV đỏ cố định ở chính giữa màn hình
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
        NSLog(@"[DudeHack] Đã khởi tạo thành công Floating Overlay Menu & ESP Layer!");
    });
}

// ==========================================
// HOOK CAMERA & XỬ LÝ AIMBOT + ESP THỰC CHIẾN
// ==========================================
void *(*old_PlayerCamera_LateUpdate)(void *self);
void *hook_PlayerCamera_LateUpdate(void *self) {
    if (self) {
        g_playerCameraInstance = self;
    }
    
    // Gọi hàm gốc của game để bảo đảm camera loop mượt mà
    void *result = old_PlayerCamera_LateUpdate(self);
    
    // Nếu cả Aim Đầu và Aim Thân đều tắt thì không tốn hiệu năng tính toán
    if (!g_aimHeadEnabled && !g_aimBodyEnabled) {
        return result;
    }
    
    // --- KHU VỰC LOGIC AIMBOT ---
    // (Bro tích hợp gọi get_PlayerListOthers() và tính toán khoảng cách/góc atan2f tại đây)
    // Ví dụ mẫu kiểm tra an toàn:
    // float targetYOffset = g_aimHeadEnabled ? 1.5f : 1.0f;
    // ... Duyệt mảng địch, tìm địch gần tâm FOV nhất ...
    // Sau khi tính ra targetYaw và targetPitch, tiến hành ghi đè an toàn:
    // safe_write_float((float *)((uintptr_t)self + 0x44), targetYaw);   // Yaw offset 0x44
    // safe_write_float((float *)((uintptr_t)self + 0x40), targetPitch); // Pitch offset 0x40
    
    return result;
}

// Constructor tiêm code vào game
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        setupOverlayWindow();
    });
    
    // Hook hàm LateUpdate của PlayerCamera
    // Bro thay OFFSET_LATEUPDATE bằng địa chỉ thực tế từ dump.cs của game
    /*
    uintptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void *targetFunc = (void *)(slide + 0xOFFSET_LATEUPDATE);
    MSHookFunction(targetFunc, (void *)hook_PlayerCamera_LateUpdate, (void **)&old_PlayerCamera_LateUpdate);
    */
}
