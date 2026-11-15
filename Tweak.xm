#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

__attribute__((constructor))
static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (!window) return;
        
        UIView *circleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 300)];
        circleView.center = CGPointMake(window.bounds.size.width / 2, window.bounds.size.height / 2);
        circleView.backgroundColor = [UIColor clearColor];
        circleView.layer.cornerRadius = 150;
        circleView.layer.borderWidth = 1.0;
        circleView.layer.borderColor = [UIColor redColor].CGColor;
        circleView.userInteractionEnabled = NO;
        
        [window addSubview:circleView];
        NSLog(@"[DudeHack] Da ve vong tron FOV!");
    });
}
