#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>

// --- BIẾN TRẠNG THÁI ---
__attribute__((unused)) static BOOL isMenuShown = NO;
__attribute__((unused)) static BOOL aimEnabled = YES;
__attribute__((unused)) static BOOL aimTargetHead = YES; // YES: Đầu (0x98), NO: Thân (0x90)
__attribute__((unused)) static BOOL espBoxEnabled = NO;
__attribute__((unused)) static BOOL espSkeletonEnabled = NO;
__attribute__((unused)) static BOOL espLineEnabled = NO;
__attribute__((unused)) static float fovRadius = 100.0f;

// UI Components
static UIWindow *modWindow = nil;
static UIButton *floatingIconButton = nil;
static UIView *menuContainerView = nil;
static UIView *fovCircleView = nil; // View vẽ vòng tròn FOV đỏ thật sự

// --- LỚP CHẶN CHẠM THÔNG MINH (CHỐNG LIỆT CẢM ỨNG HOÀN TOÀN) ---
@interface PassthroughWindow : UIWindow
@end

@implementation PassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    // Chỉ nhận cảm ứng nếu bấm vào icon hoặc menu, ngoài ra cho xuyên thấu 100% xuống game
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil;
    }
    return hitView;
}
@end

// --- VÙNG VẼ VÒNG TRÒN FOV THẬT ---
@interface FOVView : UIView
@end

@implementation FOVView
- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    if (!aimEnabled) return;
    
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;
    
    // Vẽ vòng tròn FOV màu đỏ ở chính giữa màn hình
    CGPoint center = CGPointMake(rect.size.width / 2.0f, rect.size.height / 2.0f);
    CGContextSetStrokeColorWithColor(context, [UIColor redColor].CGColor);
    CGContextSetLineWidth(context, 1.5f);
    CGContextAddArc(context, center.x, center.y, fovRadius, 0.0f, 2.0f * M_PI, 0);
    CGContextStrokePath(context);
}
@end

// --- GIAO DIỆN MOD MENU ---
@interface ModMenuManager : NSObject
+ (void)setupOverlay;
@end

@implementation ModMenuManager

+ (void)setupOverlay {
    if (modWindow) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Dùng PassthroughWindow thay vì UIWindow thường để chống liệt cảm ứng game
        modWindow = [[PassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        modWindow.windowLevel = UIWindowLevelStatusBar + 100;
        modWindow.backgroundColor = [UIColor clearColor];
        modWindow.hidden = NO;
        
        UIViewController *vc = [[UIViewController alloc] init];
        modWindow.rootViewController = vc;
        
        // 1. View vẽ vòng tròn FOV (Nằm dưới cùng, xuyên thấu cảm ứng)
        fovCircleView = [[FOVView alloc] initWithFrame:vc.view.bounds];
        fovCircleView.backgroundColor = [UIColor clearColor];
        fovCircleView.userInteractionEnabled = NO;
        [vc.view addSubview:fovCircleView];
        
        // 2. Icon tròn nhỏ nổi trên màn hình
        floatingIconButton = [UIButton buttonWithType:UIButtonTypeCustom];
        floatingIconButton.frame = CGRectMake(30, 100, 50, 50);
        floatingIconButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
        [floatingIconButton setTitle:@"DTW" forState:UIControlStateNormal];
        [floatingIconButton setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
        floatingIconButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        floatingIconButton.layer.cornerRadius = 25;
        floatingIconButton.layer.borderWidth = 1.5;
        floatingIconButton.layer.borderColor = [UIColor cyanColor].CGColor;
        [floatingIconButton addTarget:self action:@selector(toggleMenu:) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *panIcon = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleIconPan:)];
        [floatingIconButton addGestureRecognizer:panIcon];
        [vc.view addSubview:floatingIconButton];
        
        // 3. Bảng Menu Chức Năng
        menuContainerView = [[UIView alloc] initWithFrame:CGRectMake(90, 100, 220, 320)];
        menuContainerView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        menuContainerView.layer.cornerRadius = 14;
        menuContainerView.layer.borderWidth = 1.2;
        menuContainerView.layer.borderColor = [UIColor cyanColor].CGColor;
        menuContainerView.hidden = YES;
        [vc.view addSubview:menuContainerView];
        
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 200, 25)];
        titleLabel.text = @"Dude Theft Wars Mod";
        titleLabel.textColor = [UIColor cyanColor];
        titleLabel.font = [UIFont boldSystemFontOfSize:13];
        titleLabel.textAlignment = NSTextAlignmentCenter;
        [menuContainerView addSubview:titleLabel];
        
        // Nút Aim Target
        UIButton *aimBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        aimBtn.frame = CGRectMake(12, 45, 196, 32);
        [aimBtn setTitle:@"Aim: Đầu (0x98)" forState:UIControlStateNormal];
        [aimBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        aimBtn.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.5];
        aimBtn.layer.cornerRadius = 6;
        [aimBtn addTarget:self action:@selector(clickAimTarget:) forControlEvents:UIControlEventTouchUpInside];
        [menuContainerView addSubview:aimBtn];
        
        // Nút ESP Box
        UIButton *boxBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        boxBtn.frame = CGRectMake(12, 85, 196, 32);
        [boxBtn setTitle:@"ESP Box: Tắt" forState:UIControlStateNormal];
        [boxBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        boxBtn.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.5];
        boxBtn.layer.cornerRadius = 6;
        boxBtn.tag = 301;
        [boxBtn addTarget:self action:@selector(clickFeature:) forControlEvents:UIControlEventTouchUpInside];
        [menuContainerView addSubview:boxBtn];
        
        // Nút ESP Skeleton
        UIButton *skelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        skelBtn.frame = CGRectMake(12, 125, 196, 32);
        [skelBtn setTitle:@"ESP Skeleton: Tắt" forState:UIControlStateNormal];
        [skelBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        skelBtn.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.5];
        skelBtn.layer.cornerRadius = 6;
        skelBtn.tag = 302;
        [skelBtn addTarget:self action:@selector(clickFeature:) forControlEvents:UIControlEventTouchUpInside];
        [menuContainerView addSubview:skelBtn];
        
        // Nút ESP Line
        UIButton *lineBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        lineBtn.frame = CGRectMake(12, 165, 196, 32);
        [lineBtn setTitle:@"ESP Line: Tắt" forState:UIControlStateNormal];
        [lineBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        lineBtn.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.5];
        lineBtn.layer.cornerRadius = 6;
        lineBtn.tag = 303;
        [lineBtn addTarget:self action:@selector(clickFeature:) forControlEvents:UIControlEventTouchUpInside];
        [menuContainerView addSubview:lineBtn];
        
        // Slider FOV
        UILabel *fovLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 205, 196, 20)];
        fovLbl.text = @"FOV Radius:";
        fovLbl.textColor = [UIColor whiteColor];
        fovLbl.font = [UIFont systemFontOfSize:11];
        [menuContainerView addSubview:fovLbl];
        
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, 225, 196, 30)];
        slider.minimumValue = 50.0f;
        slider.maximumValue = 300.0f;
        slider.value = fovRadius;
        [slider addTarget:self action:@selector(changeFov:) forControlEvents:UIControlEventValueChanged];
        [menuContainerView addSubview:slider];
        
        // Nút Đóng Menu
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(12, 268, 196, 35);
        [closeBtn setTitle:@"Đóng Menu" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        closeBtn.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.6];
        closeBtn.layer.cornerRadius = 6;
        [closeBtn addTarget:self action:@selector(toggleMenu:) forControlEvents:UIControlEventTouchUpInside];
        [menuContainerView addSubview:closeBtn];
    });
}

+ (void)toggleMenu:(id)sender {
    isMenuShown = !isMenuShown;
    menuContainerView.hidden = !isMenuShown;
}

+ (void)handleIconPan:(UIPanGestureRecognizer *)gesture {
    UIView *btn = floatingIconButton;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];
    menuContainerView.center = CGPointMake(btn.center.x + 120, btn.center.y);
}

+ (void)clickAimTarget:(UIButton *)sender {
    aimTargetHead = !aimTargetHead;
    if (aimTargetHead) {
        [sender setTitle:@"Aim: Đầu (0x98)" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
    } else {
        [sender setTitle:@"Aim: Thân (0x90)" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
    }
}

+ (void)clickFeature:(UIButton *)sender {
    if (sender.tag == 301) {
        espBoxEnabled = !espBoxEnabled;
        [sender setTitle:espBoxEnabled ? @"ESP Box: Bật" : @"ESP Box: Tắt" forState:UIControlStateNormal];
        [sender setTitleColor:espBoxEnabled ? [UIColor greenColor] : [UIColor redColor] forState:UIControlStateNormal];
    } else if (sender.tag == 302) {
        espSkeletonEnabled = !espSkeletonEnabled;
        [sender setTitle:espSkeletonEnabled ? @"ESP Skeleton: Bật" : @"ESP Skeleton: Tắt" forState:UIControlStateNormal];
        [sender setTitleColor:espSkeletonEnabled ? [UIColor greenColor] : [UIColor redColor] forState:UIControlStateNormal];
    } else if (sender.tag == 303) {
        espLineEnabled = !espLineEnabled;
        [sender setTitle:espLineEnabled ? @"ESP Line: Bật" : @"ESP Line: Tắt" forState:UIControlStateNormal];
        [sender setTitleColor:espLineEnabled ? [UIColor greenColor] : [UIColor redColor] forState:UIControlStateNormal];
    }
}

+ (void)changeFov:(UISlider *)slider {
    fovRadius = slider.value;
    [fovCircleView setNeedsDisplay]; // Cập nhật lại kích thước vòng tròn FOV ngay lập tức khi kéo slider
}

@end

// Kích hoạt khi game load
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ModMenuManager setupOverlay];
    });
}
