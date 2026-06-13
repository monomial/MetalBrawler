#include "ShopSystem.h"
#include "Simulation/World.h"
#include <math.h>

static constexpr float kShopBuyRadius = 70.0f;

static bool is_living_player(World& world, EntityID playerID) {
    if (!world.player_tags().present(playerID)) return false;
    if (!world.has_component<PositionComponent>(playerID)) return false;
    if (!world.has_component<HealthComponent>(playerID)) return false;
    if (world.get_component<HealthComponent>(playerID).current <= 0) return false;
    if (world.has_component<DownedComponent>(playerID)) return false;
    if (world.has_component<AnimationComponent>(playerID) &&
        world.get_component<AnimationComponent>(playerID).dying) return false;
    return true;
}

void ShopSystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return;

    uint32_t count = world.entity_count();
    for (EntityID itemID = 0; itemID < count; ++itemID) {
        if (!world.shop_items().present(itemID)) continue;
        if (!world.has_component<PositionComponent>(itemID)) continue;

        ShopItemComponent& item = world.get_component<ShopItemComponent>(itemID);
        const PositionComponent& ipos = world.get_component<PositionComponent>(itemID);
        bool bought = false;

        for (EntityID playerID = 0; playerID < count; ++playerID) {
            if (!is_living_player(world, playerID)) continue;
            const PlayerTagComponent& tag = world.get_component<PlayerTagComponent>(playerID);
            int slot = (tag.playerIndex < 4) ? tag.playerIndex : 0;
            bool attack = world.current_input(slot).attack;
            bool pressed = attack && !item.prevAttack[slot];
            item.prevAttack[slot] = attack;
            if (!pressed) continue;

            const PositionComponent& ppos = world.get_component<PositionComponent>(playerID);
            float dx = ppos.x - ipos.x;
            float dy = ppos.y - ipos.y;
            if (dx * dx + dy * dy > kShopBuyRadius * kShopBuyRadius) continue;
            if (world.scrap() < item.price) continue;

            world.set_scrap(world.scrap() - item.price);
            world.events().emit_shop_purchase(item.perkID, item.price, itemID);
            world.defer_destroy(itemID);
            bought = true;
            break;
        }
        if (bought) continue;
    }
}
