db = db.getSiblingDB('commerce');
db.events.drop(); // Clean start
db.events.insertMany([
    { user_id: 1, event_type: "login", timestamp: new Date(), metadata: { device: "mobile" } },
    { user_id: 1, event_type: "view_item", timestamp: new Date(), metadata: { item_id: "A100" } },
    { user_id: 2, event_type: "login", timestamp: new Date(), metadata: { device: "desktop" } },
    { user_id: 2, event_type: "add_to_cart", timestamp: new Date(), metadata: { item_id: "B200", quantity: 1 } },
    { user_id: 3, event_type: "login", timestamp: new Date(), metadata: { device: "tablet" } }
]);
