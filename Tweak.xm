#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach.h>
#include <substrate.h>

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
static UIWindow *overlayWindow = nil;
static UIView *espDrawView = nil;
static CAShapeLayer *fovCircleLayer = nil;

// Hàm đọc bộ nhớ an toàn thuần C (__unused để tránh lỗi -Werror)
__unused static bool safe_read(void *address, void *output, size_t size) {
    if (!address || !output) return false;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address, size, (vm_address_t)output, &outSize);
    return (kr == KERN_SUCCESS && outSize == size);
}

// Hàm ghi bộ nhớ an toàn cho float (__unused để tránh lỗi -Werror)
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
// GIAO DIỆN MOD MENU NỔI (ĐÃ FIX CHẶN CHẠM GAME)
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
    self.view.userInteractionEnabled = NO; // Cho phép chạm xuyên thấu màn hình game
    
    // Khung Menu chính (Bật tương tác riêng cho khung này)
    self.menuContainer = [[UIView alloc] initWithFrame:CGRectMake(20, 80, 240, 320)];
    self.menuContainer.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    self.menuContainer.layer.cornerRadius = 12.0f;
    self.menuContainer.layer.borderWidth = 1.5f;
    self.menuContainer.layer.borderColor = [UIColor redColor].CGColor;
    self.menuContainer.userInteractionEnabled = YES;
    [self.view addSubview:self.menuContainer];
    
    // Tiêu đề Menu
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 220, 30)];
    titleLabel.text = @"🔥 DudeHack Pro 🔥";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:15];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.menuContainer addSubview:titleLabel];
    
    // Hàng Aim Đầu
    [self addRowWithFrame:CGRectMake(10, 50, 220, 30) title:@"Aim Đầu (Head)" action:@selector(toggleAimHead:) assignSwitch:&_switchAimHead];
    
    // Hàng Aim Thân
    [self addRowWithFrame:CGRectMake(10, 90, 220, 30) title:@"Aim Thân (Body)" action:@selector(toggleAimBody:) assignSwitch:&_switchAimBody];
    
    // Hàng ESP Box
    [self addRowWithFrame:CGRectMake(10, 130, 220, 30) title:@"ESP Khung (Box)" action:@selector(toggleEspBox:) assignSwitch:&_switchEspBox];
    
    // Hàng ESP Line
    [self addRowWithFrame:CGRectMake(10, 170, 220, 30) title:@"ESP Đường (Line)" action:@selector(toggleEspLine:) assignSwitch:&_switchEspLine];
    
    // Slider chỉnh FOV
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
    
    // Nút thu nhỏ/mở Menu nhanh hình tròn chữ HACK
    UIButton *collapseBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    collapseBtn.frame = CGRectMake(20, 40, 45, 45);
    collapseBtn.backgroundColor = [UIColor redColor];
    [collapseBtn setTitle:@"HACK" forState:UIControlStateNormal];
    [collapseBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    collapseBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    collapseBtn.layer.cornerRadius = 22.5f;
    collapseBtn.userInteractionEnabled = YES;
    [collapseBtn addTarget:self action:@selector(toggleMenu:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:collapseBtn];
}

- (void)addRowWithFrame:(CGRect)frame title:(NSString *)title action:(SEL)action assignSwitch:(UISwitch **)targetSwitch {
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, frame.size.width - 60, frame.size.height)];
    lbl.text = title;
    lbl.textColor = [UIColor whiteColor];
    lbl.font = [UIFont systemFontOfSize:13];
    
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(frame.size.width - 55, (frame.size.height - 30)/2, 50, 30)];
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    
    UIView *rowView = [[UIView alloc] initWithFrame:frame];
    rowView.userInteractionEnabled = YES;
    [rowView addSubview:lbl];
    [rowView addSubview:sw];
    [self.menuContainer addSubview:rowView];
    
    if (targetSwitch) *targetSwitch = sw;
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

- (void)toggleMenu:(UIButton *)sender {
    self.menuContainer.hidden = !self.menuContainer.hidden;
}

@end

// ==========================================
// KHỞI TẠO CỬA SỔ NỔI & ESP LAYER
// ==========================================
static void setupOverlayWindow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (overlayWindow) return;
        
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        overlayWindow = [[UIWindow alloc] initWithFrame:screenBounds];
        overlayWindow.windowLevel = UIWindowLevelAlert + 100;
        overlayWindow.backgroundColor = [UIColor clearColor];
        overlayWindow.userInteractionEnabled = YES;
        
        ModMenuViewController *menuVC = [[ModMenuViewController alloc] init];
        overlayWindow.rootViewController = menuVC;
        
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
        NSLog(@"[DudeHack] Đã khởi tạo thành công hệ thống Menu Pro!");
    });
}

// Constructor tiêm code
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        setupOverlayWindow();
    });
}
