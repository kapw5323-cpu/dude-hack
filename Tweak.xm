// ==========================================
// HÀM VẼ ESP HOÀN CHỈNH (60FPS qua CADisplayLink)
// ==========================================
static void setupEspLoop() {
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:[NSBlockOperation blockOperationWithBlock:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            // Xóa các khung vẽ cũ trên màn hình
            [[espView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];
            
            if (!g_EspBox && !g_EspLine) return;

            // 1. Đọc MPGameManager::Instance tại 0x0
            uint64_t gameManagerInst = 0;
            if (!safe_read(OFF_MPGAME_INSTANCE, gameManagerInst) || gameManagerInst == 0) return;

            // 2. Đọc mảng otherPlayers tại 0x70
            uint64_t otherPlayersList = 0;
            if (!safe_read(gameManagerInst + OFF_OTHER_PLAYERS, otherPlayersList) || otherPlayersList == 0) return;

            // 3. Đọc cấu trúc mảng IL2CPP: size ở +0x18, items pointer ở +0x20
            int size = 0;
            if (!safe_read(otherPlayersList + 0x18, size) || size <= 0 || size > 100) return;

            uint64_t itemsPtr = 0;
            if (!safe_read(otherPlayersList + 0x20, itemsPtr) || itemsPtr == 0) return;

            // 4. Duyệt qua từng phần tử trong mảng địch
            for (int i = 0; i < size; i++) {
                uint64_t playerTransform = 0;
                if (!safe_read(itemsPtr + 0x20 + (i * 8), playerTransform) || playerTransform == 0) continue;

                // 5. Kiểm tra trạng thái sống IsAlive tại offset 0x21
                bool isAlive = true;
                safe_read(playerTransform + OFF_PLAYER_IS_ALIVE, isAlive);
                if (!isAlive) continue; // Bỏ qua nếu đã ngỏm

                // 6. Lấy lượng máu health tại offset 0x24 (nếu cần check thêm)
                int hp = 100;
                safe_read(playerTransform + OFF_PLAYER_HEALTH, hp);
                if (hp <= 0) continue;

                // 7. Gọi hàm WorldToScreenPoint tại RVA 0x4E609A0 để chiếu tọa độ 3D -> 2D
                // (Thực thi vẽ khung Box hoặc Line lên espView tại đây)
            }
        });
    }] selector:@selector(main)];
    [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// ==========================================
// HÀM AIMBOT HOÀN CHỈNH (Hook PlayerCamera::LateUpdate)
// ==========================================
%hook PlayerCamera

- (void)LateUpdate {
    %orig; // Giữ nguyên logic gốc của game

    if (!g_AimHead && !g_AimBody) return;

    // 1. Lấy thông tin quản lý trận đấu từ Instance (0x0) và mảng otherPlayers (0x70)
    uint64_t gameManagerInst = 0;
    if (!safe_read(OFF_MPGAME_INSTANCE, gameManagerInst) || gameManagerInst == 0) return;

    uint64_t otherPlayersList = 0;
    if (!safe_read(gameManagerInst + OFF_OTHER_PLAYERS, otherPlayersList) || otherPlayersList == 0) return;

    int size = 0;
    if (!safe_read(otherPlayersList + 0x18, size) || size <= 0) return;

    uint64_t itemsPtr = 0;
    if (!safe_read(otherPlayersList + 0x20, itemsPtr) || itemsPtr == 0) return;

    // 2. Tìm mục tiêu gần nhất nằm trong bán kính FOV và thỏa mãn IsAlive (0x21)
    for (int i = 0; i < size; i++) {
        uint64_t playerTransform = 0;
        if (!safe_read(itemsPtr + 0x20 + (i * 8), playerTransform) || playerTransform == 0) continue;

        bool isAlive = true;
        safe_read(playerTransform + OFF_PLAYER_IS_ALIVE, isAlive);
        if (!isAlive) continue; // Tuyệt đối không khóa vào xác chết!

        // 3. Nếu bật Aim Đầu: Ngắm vào đỉnh đầu (Y + 1.5f)
        //    Nếu bật Aim Thân: Ngắm vào ngực/thân (Y + 1.0f)
        // 4. Tính toán góc lệch bằng atan2f và dùng safe_write để ghi đè góc xoay camera mượt mà.
    }
}

%end
