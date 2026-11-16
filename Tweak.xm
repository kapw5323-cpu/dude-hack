#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>

// --- BIẾN TRẠNG THÁI MOD MENU & TÍNH NĂNG ---
static BOOL isOpen = YES;
static BOOL aimEnabled = YES;
static BOOL aimTargetHead = YES; // YES: Khóa đầu (0x98), NO: Khóa thân (0x90)
static BOOL espBoxEnabled = NO;
static BOOL espSkeletonEnabled = NO;
static BOOL espLineEnabled = NO;
static float fovRadius = 100.0f; // Bán kính vòng tròn FOV

// UI Components toàn cục
static UIWindow *modWindow = nil;
static UIView *floatingMenu = nil;
static UIView *espOverlayView = nil;

// --- HÀM AN TOÀN ĐỌC/GHI BỘ NHỚ (CHỐNG VĂNG GAME) ---
static BOOL safe_vm_read(mach_vm_address_t address, void *buffer, mach_msg_type_number_t size) {
    if (address == 0 || buffer == NULL) return NO;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), address, size, (mach_vm_address_t)buffer, &outSize);
    return (kr == KERN_SUCCESS && outSize == size);
}

static BOOL safe_vm_write(mach_vm_address_t address, void *data, mach_msg_type_number_t size) {
    if (address == 0 || data == NULL) return NO;
    mach_port_t self_task = mach_task_self();
    kern_return_t kr = vm_protect(self_task, address, size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return NO;
    kr = vm_write(self_task, address, (vm_offset_t)data, size);
    return (kr == KERN_SUCCESS);
}

// --- GIAO DIỆN MOD MENU NỔI ---
@interface ModMenuController : NSObject
+ (void)setupMenu;
@end

@implementation ModMenuController

+ (void)setupMenu {
    if (modWindow) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        modWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        modWindow.windowLevel = UIWindowLevelAlert + 100; // Đảm bảo luôn hiện đè lên trên game
        modWindow.backgroundColor = [UIColor clearColor];
        modWindow.hidden = NO;
        
        UIViewController *vc = [[UIViewController alloc] init];
        modWindow.rootViewController = vc;
        
        // View vẽ đồ họa ESP (Box, Skeleton, Line, FOV Circle)
        espOverlayView = [[UIView alloc] initWithFrame:vc.view.bounds];
        espOverlayView.backgroundColor = [UIColor clearColor];
        espOverlayView.userInteractionEnabled = NO;
        [vc.view addSubview:espOverlayView];
        
        // Khung Menu Nổi (Có thể kéo thả)
        floatingMenu = [[UIView alloc] initWithFrame:CGRectMake(40, 60, 240, 360)];
        floatingMenu.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        floatingMenu.layer.cornerRadius = 14;
        floatingMenu.layer.borderWidth = 1.5;
        floatingMenu.layer.borderColor = [UIColor cyanColor].CGColor;
        [vc.view addSubview:floatingMenu];
        
        // Tiêu đề Menu
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 220, 30)];
        titleLabel.text = @"Dude Theft Wars Mod";
        titleLabel.textColor = [UIColor cyanColor];
        titleLabel.font = [UIFont boldSystemFontOfSize:15];
        titleLabel.textAlignment = NSTextAlignmentCenter;
        [floatingMenu addSubview:titleLabel];
        
        // Nút bật/tắt Aim (Loại trừ Đầu / Thân)
        UIButton *aimBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        aimBtn.frame = CGRectMake(15, 50, 210, 35);
        [aimBtn setTitle:@"Aim Target: Đầu (0x98)" forState:UIControlStateNormal];
        [aimBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        aimBtn.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.5];
        aimBtn.layer.cornerRadius = 6;
        [aimBtn addTarget:self action:@selector(toggleAimTarget:) forControlEvents:UIControlEventTouchUpInside];
        [floatingMenu addSubview:aimBtn];
        
        // Nút ESP Box
        UIButton *boxBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        boxBtn.frame = CGRectMake(15, 95, 210, 35);
        [boxBtn setTitle:@"ESP Box: Tắt" forState:UIControlStateNormal];
        [boxBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        boxBtn.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.5];
        boxBtn.layer.cornerRadius = 6;
        boxBtn.tag = 201;
        [boxBtn addTarget:self action:@selector(toggleFeature:) forControlEvents:UIControlEventTouchUpInside];
        [floatingMenu addSubview:boxBtn];
        
        // Nút ESP Skeleton
        UIButton *skelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        skelBtn.frame = CGRectMake(15, 140, 210, 35);
        [skelBtn setTitle:@"ESP Skeleton: Tắt" forState:UIControlStateNormal];
        [skelBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        skelBtn.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.5];
        skelBtn.layer.cornerRadius = 6;
        skelBtn.tag = 202;
        [skelBtn addTarget:self action:@selector(toggleFeature:) forControlEvents:UIControlEventTouchUpInside];
        [floatingMenu addSubview:skelBtn];
        
        // Nút ESP Line
        UIButton *lineBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        lineBtn.frame = CGRectMake(15, 185, 210, 35);
        [lineBtn setTitle:@"ESP Line: Tắt" forState:UIControlStateNormal];
        [lineBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        lineBtn.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.5];
        lineBtn.layer.cornerRadius = 6;
        lineBtn.tag = 203;
        [lineBtn addTarget:self action:@selector(toggleFeature:) forControlEvents:UIControlEventTouchUpInside];
        [floatingMenu addSubview:lineBtn];
        
        // Nhãn FOV Slider
        UILabel *fovLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 230, 210, 20)];
        fovLabel.text = @"FOV Radius:";
        fovLabel.textColor = [UIColor whiteColor];
        fovLabel.font = [UIFont systemFontOfSize:12];
        [floatingMenu addSubview:fovLabel];
        
        // Thanh trượt (UISlider) chỉnh bán kính FOV
        UISlider *fovSlider = [[UISlider alloc] initWithFrame:CGRectMake(15, 255, 210, 30)];
        fovSlider.minimumValue = 50.0f;
        fovSlider.maximumValue = 300.0f;
        fovSlider.value = fovRadius;
        [fovSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [floatingMenu addSubview:fovSlider];
        
        // Nút Ẩn / Hiện Menu (Collapse)
        UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        hideBtn.frame = CGRectMake(15, 305, 210, 35);
        [hideBtn setTitle:@"Ẩn Menu" forState:UIControlStateNormal];
        [hideBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        hideBtn.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.5];
        hideBtn.layer.cornerRadius = 6;
        [hideBtn addTarget:self action:@selector(toggleMenuVisibility:) forControlEvents:UIControlEventTouchUpInside];
        [floatingMenu addSubview:hideBtn];
        
        // Cử chỉ kéo thả (Pan Gesture) cho Menu nổi
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [floatingMenu addGestureRecognizer:pan];
    });
}

+ (void)toggleAimTarget:(UIButton *)sender {
    aimTargetHead = !aimTargetHead;
    if (aimTargetHead) {
        [sender setTitle:@"Aim Target: Đầu (0x98)" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
    } else {
        [sender setTitle:@"Aim Target: Thân (0x90)" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
    }
}

+ (void)toggleFeature:(UIButton *)sender {
    if (sender.tag == 201) {
        espBoxEnabled = !espBoxEnabled;
        [sender setTitle:espBoxEnabled ? @"ESP Box: Bật" : @"ESP Box: Tắt" forState:UIControlStateNormal];
        [sender setTitleColor:espBoxEnabled ? [UIColor greenColor] : [UIColor redColor] forState:UIControlStateNormal];
    } else if (sender.tag == 202) {
        espSkeletonEnabled = !espSkeletonEnabled;
        [sender setTitle:espSkeletonEnabled ? @"ESP Skeleton: Bật" : @"ESP Skeleton: Tắt" forState:UIControlStateNormal];
        [sender setTitleColor:espSkeletonEnabled ? [UIColor greenColor] : [UIColor redColor] forState:UIControlStateNormal];
    } else if (sender.tag == 203) {
        espLineEnabled = !espLineEnabled;
        [sender setTitle:espLineEnabled ? @"ESP Line: Bật" : @"ESP Line: Tắt" forState:UIControlStateNormal];
        [sender setTitleColor:espLineEnabled ? [UIColor greenColor] : [UIColor redColor] forState:UIControlStateNormal];
    }
}

+ (void)sliderChanged:(UISlider *)sender {
    fovRadius = sender.value;
}

+ (void)toggleMenuVisibility:(UIButton *)sender {
    isOpen = !isOpen;
    for (UIView *subview in floatingMenu.subviews) {
        if (subview != sender) {
            subview.hidden = !isOpen;
        }
    }
    CGRect frame = floatingMenu.frame;
    frame.size.height = isOpen ? 360 : 50;
    floatingMenu.frame = frame;
    [sender setTitle:isOpen ? @"Ẩn Menu" : @"Hiện Menu" forState:UIControlStateNormal];
}

+ (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *piece = floatingMenu;
    CGPoint translation = [gesture translationInView:piece.superview];
    piece.center = CGPointMake(piece.center.x + translation.x, piece.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:piece.superview];
}

@end

// --- KÍCH HOẠT MENU KHI GAME CHẠY ---
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ModMenuController setupMenu];
    });
}
