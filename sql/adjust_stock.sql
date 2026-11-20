-- =====================================================================
-- adjust_stock.sql : ฟังก์ชันปรับยอดคงเหลือของล็อต (stock adjustment)
-- รันใน Supabase SQL Editor หลัง schema.sql / seed.sql (รันซ้ำได้)
-- ต้องรันใหม่ทุกครั้งหลัง reset ด้วย schema.sql
--
-- ทำในธุรกรรมเดียว:
--   1) ล็อกแถว stock และตรวจว่ายอดปัจจุบันยังเท่ากับที่ผู้ใช้เห็น (กันนับทับกัน)
--   2) อัปเดต stock.qty_on_hand เป็นยอดนับจริง
--   3) บันทึก stock_adjustments (เลขที่ ADJ-xxx, qty_change, มูลค่า = ส่วนต่าง × ราคาทุน)
--   4) บันทึก change_log ว่าใครแก้ เพราะอะไร
-- ข้อความ error เป็นภาษาไทย เพื่อให้ /api/admin ส่งต่อไปแสดงในหน้า admin.html ได้ตรง ๆ
-- =====================================================================

create or replace function public.adjust_stock(
  p_stock_id     text,
  p_expected_qty integer,   -- ยอดที่ผู้ใช้เห็นบนหน้าจอตอนเปิดกล่อง
  p_new_qty      integer,   -- ยอดนับจริง
  p_adj_type     text,      -- ประเภท เช่น นับสต็อกแล้วยอดไม่ตรง
  p_reason       text,      -- เหตุผล/รายละเอียด
  p_by           text       -- รหัสเภสัชกร
) returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_row    public.stock%rowtype;
  v_change integer;
  v_id     text;
  v_today  date := (now() at time zone 'Asia/Bangkok')::date;
begin
  if p_new_qty is null or p_new_qty < 0 then
    raise exception 'ยอดใหม่ต้องเป็นจำนวนเต็มตั้งแต่ 0 ขึ้นไป';
  end if;
  if coalesce(btrim(p_adj_type), '') = '' then
    raise exception 'กรุณาเลือกประเภทการปรับยอด';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'กรุณาระบุเหตุผล';
  end if;
  if coalesce(btrim(p_by), '') = '' then
    raise exception 'ไม่พบรหัสเภสัชกร';
  end if;

  -- ล็อกแถวไว้จนจบธุรกรรม การขายยาที่เกิดพร้อมกันจะรอคิว
  select * into v_row from public.stock where stock_id = p_stock_id for update;
  if not found then
    raise exception 'ไม่พบล็อต %', p_stock_id;
  end if;
  if v_row.status = 'written_off' then
    raise exception 'ล็อต % ตัดจำหน่ายแล้ว ปรับยอดไม่ได้', p_stock_id;
  end if;
  if p_expected_qty is null or v_row.qty_on_hand <> p_expected_qty then
    raise exception 'ยอดล็อต % เปลี่ยนไปแล้ว (ตอนนี้ %) กรุณาโหลดข้อมูลใหม่แล้วนับอีกครั้ง',
      p_stock_id, v_row.qty_on_hand;
  end if;

  v_change := p_new_qty - v_row.qty_on_hand;
  if v_change = 0 then
    raise exception 'ยอดใหม่เท่ากับยอดเดิม ไม่มีอะไรต้องปรับ';
  end if;

  -- ออกเลขที่ ADJ-xxx ต่อจากเลขสูงสุด (ล็อกกันออกเลขซ้ำเมื่อปรับหลายล็อตพร้อมกัน)
  perform pg_advisory_xact_lock(hashtext('stock_adjustments.adjustment_id'));
  select 'ADJ-' || lpad((coalesce(max(substring(adjustment_id from '^ADJ-([0-9]+)$')::int), 0) + 1)::text, 3, '0')
    into v_id
    from public.stock_adjustments;

  update public.stock set qty_on_hand = p_new_qty where stock_id = p_stock_id;

  insert into public.stock_adjustments
    (adjustment_id, adj_date, stock_id, qty_change, reason, value, status, note)
  values
    (v_id, v_today, p_stock_id, v_change, btrim(p_adj_type),
     round(v_change * v_row.unit_cost, 2), 'completed', btrim(p_reason));

  insert into public.change_log
    (file, record_id, field, old_value, new_value, reason, severity, status, changed_by, changed_on)
  values
    ('stock', p_stock_id, 'qty_on_hand', to_jsonb(v_row.qty_on_hand), to_jsonb(p_new_qty),
     btrim(p_adj_type) || ': ' || btrim(p_reason) || ' (' || v_id || ')', null, 'completed', btrim(p_by), v_today);

  return jsonb_build_object(
    'adjustment_id', v_id,
    'stock_id',      p_stock_id,
    'old_qty',       v_row.qty_on_hand,
    'new_qty',       p_new_qty,
    'qty_change',    v_change,
    'value',         round(v_change * v_row.unit_cost, 2)
  );
end;
$$;

-- สิทธิ์: เรียกได้เฉพาะเซิร์ฟเวอร์ (service_role ผ่าน /api/admin)
-- ฟังก์ชันใหม่ใน Postgres เรียกได้ทุกคนโดยค่าเริ่มต้น ต้องถอนสิทธิ์ ไม่อย่างนั้น key สาธารณะจะเรียก RPC นี้ได้
revoke all on function public.adjust_stock(text, integer, integer, text, text, text) from public, anon, authenticated;
grant execute on function public.adjust_stock(text, integer, integer, text, text, text) to service_role;
