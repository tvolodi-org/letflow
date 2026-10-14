local items = ctx.input.line_items
local rate = ctx.input.tax_rate_bp
if #items == 0 then fail("empty_order") end
local subtotal = 0
for _, item in ipairs(items) do
  if item.qty > 10000 then fail("quantity_too_large") end
  subtotal = subtotal + item.qty * item.unit_price_cents
end
local tax = math.tointeger(math.floor((subtotal * rate + 5000) / 10000))
local total = subtotal + tax
local tier
if total < 100000 then tier = "auto"
elseif total < 1000000 then tier = "manager"
elseif total < 10000000 then tier = "director"
else tier = "board" end
return { subtotal_cents = subtotal, tax_cents = tax, total_cents = total, approval_tier = tier }
