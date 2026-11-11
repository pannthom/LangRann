-- =====================================================================
--  ระบบหลังร้านรับซื้อของเก่า — โครงสร้างฐานข้อมูล Supabase
--  วิธีใช้: Supabase > SQL Editor > New query > วางทั้งไฟล์นี้ > Run
--  รันซ้ำได้ ไม่ทำให้ข้อมูลหาย
--
--  สิทธิ์ผู้ใช้
--    admin    ทำได้ทุกอย่าง: แก้ราคา/ลบสินค้า ดู dashboard ตั้งค่าร้าน จัดการผู้ใช้
--    staff    คิดเงิน (รับซื้อ/ขาย) + ออกใบเสร็จ ดูได้เฉพาะใบเสร็จที่ตัวเองออก
--    pending  สมัครแล้วรอ admin อนุมัติ ยังไม่เห็นข้อมูลอะไร
--    disabled ถูกระงับ
--  บัญชีแรกที่สมัครจะเป็น admin อัตโนมัติ
-- =====================================================================

-- ---------- ตาราง ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  username   text not null unique,
  role       text not null default 'pending'
             check (role in ('pending','staff','admin','disabled')),
  created_at timestamptz not null default now()
);

create table if not exists public.shop_settings (
  id   int primary key check (id = 1),
  data jsonb not null default '{}'::jsonb
);

create table if not exists public.materials (
  id         text primary key,
  data       jsonb   not null,            -- ชื่อ, sku, หมวด, หน่วย, ราคารับซื้อ/ขาย, รูป
  seq        bigint generated always as identity,
  stock      numeric not null default 0,  -- แยกคอลัมน์ เพื่อให้พนักงานคิดเงินแล้วสต๊อกขยับได้โดยไม่ชนกับการแก้ราคา
  updated_at timestamptz not null default now()
);

create table if not exists public.overheads (
  id   text primary key,
  data jsonb not null
);

create table if not exists public.purchases (
  id         text primary key,
  no         int  not null,
  date       timestamptz not null,
  created_by uuid references auth.users(id) on delete set null,
  data       jsonb not null
);
create index if not exists purchases_date_idx on public.purchases(date);
create index if not exists purchases_user_idx on public.purchases(created_by);

create table if not exists public.sales (
  id         text primary key,
  no         int  not null,
  date       timestamptz not null,
  created_by uuid references auth.users(id) on delete set null,
  data       jsonb not null
);
create index if not exists sales_date_idx on public.sales(date);
create index if not exists sales_user_idx on public.sales(created_by);

-- ---------- ตัวช่วย ----------
create or replace function public.my_role()
returns text
language sql stable security definer set search_path = public
as $$ select role from public.profiles where id = auth.uid() $$;

-- สมัครสมาชิก -> สร้างโปรไฟล์ (คนแรก = admin, คนต่อไป = pending)
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  uname text;
begin
  uname := lower(coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1)));
  insert into public.profiles(id, username, role)
  values (
    new.id, uname,
    case when exists(select 1 from public.profiles) then 'pending' else 'admin' end
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- บันทึกรายการรับซื้อ (พนักงานเรียกได้) ----------
-- เลขใบเสร็จออกจากฝั่งเซิร์ฟเวอร์ ไม่ซ้ำแม้หลายเครื่องกดพร้อมกัน
create or replace function public.record_purchase(doc jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  r   text := public.my_role();
  n   int;
  pid text := coalesce(doc->>'id', 'pu_' || gen_random_uuid()::text);
  it  jsonb;
  d   jsonb;
begin
  if r not in ('admin','staff') then raise exception 'no permission'; end if;
  lock table public.purchases in share row exclusive mode;
  select coalesce(max(no),0) + 1 into n from public.purchases;
  d := (doc - 'no') || jsonb_build_object('id', pid, 'no', n);
  insert into public.purchases(id, no, date, created_by, data)
  values (pid, n, coalesce((doc->>'date')::timestamptz, now()), auth.uid(), d);
  for it in select * from jsonb_array_elements(doc->'items') loop
    update public.materials
       set stock = round(stock + (it->>'qty')::numeric, 3), updated_at = now()
     where id = it->>'mid';
  end loop;
  return jsonb_build_object('id', pid, 'no', n);
end $$;

-- ---------- บันทึกรายการขาย ----------
create or replace function public.record_sale(doc jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  r   text := public.my_role();
  n   int;
  sid text := coalesce(doc->>'id', 'sl_' || gen_random_uuid()::text);
  it  jsonb;
  d   jsonb;
  cur numeric;
begin
  if r not in ('admin','staff') then raise exception 'no permission'; end if;
  -- ขายส่ง (ล็อตใหญ่) ทำได้เฉพาะ admin
  if coalesce((doc->>'wholesale')::boolean,false) and r <> 'admin' then raise exception 'no permission'; end if;
  lock table public.sales in share row exclusive mode;
  for it in select * from jsonb_array_elements(doc->'items') loop
    select stock into cur from public.materials where id = it->>'mid' for update;
    if cur is null or cur < (it->>'qty')::numeric then
      raise exception 'insufficient stock: %', coalesce(it->>'name','?');
    end if;
  end loop;
  select coalesce(max(no),0) + 1 into n from public.sales;
  d := (doc - 'no') || jsonb_build_object('id', sid, 'no', n);
  insert into public.sales(id, no, date, created_by, data)
  values (sid, n, coalesce((doc->>'date')::timestamptz, now()), auth.uid(), d);
  for it in select * from jsonb_array_elements(doc->'items') loop
    update public.materials
       set stock = round(stock - (it->>'qty')::numeric, 3), updated_at = now()
     where id = it->>'mid';
  end loop;
  return jsonb_build_object('id', sid, 'no', n);
end $$;

grant execute on function public.record_purchase(jsonb) to authenticated;
grant execute on function public.record_sale(jsonb)     to authenticated;
grant execute on function public.my_role()              to authenticated;

-- ---------- สิทธิ์ระดับแถว (Row Level Security) ----------
alter table public.profiles      enable row level security;
alter table public.shop_settings enable row level security;
alter table public.materials     enable row level security;
alter table public.overheads     enable row level security;
alter table public.purchases     enable row level security;
alter table public.sales         enable row level security;

-- profiles: เห็นของตัวเอง, admin เห็นและเปลี่ยนสิทธิ์ทุกคนได้
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.my_role() = 'admin');
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (public.my_role() = 'admin' and id <> auth.uid())   -- admin เปลี่ยนสิทธิ์ตัวเองไม่ได้ กันล็อกตัวเองออก
  with check (public.my_role() = 'admin');
drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles for delete to authenticated
  using (public.my_role() = 'admin' and id <> auth.uid());

-- shop_settings: admin และ staff อ่านได้ (ต้องใช้ตอนพิมพ์ใบเสร็จ), admin แก้ได้คนเดียว
drop policy if exists settings_select on public.shop_settings;
create policy settings_select on public.shop_settings for select to authenticated
  using (public.my_role() in ('admin','staff'));
drop policy if exists settings_write on public.shop_settings;
create policy settings_write on public.shop_settings for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- materials: admin และ staff อ่านได้, admin เพิ่ม/แก้/ลบได้คนเดียว
drop policy if exists materials_select on public.materials;
create policy materials_select on public.materials for select to authenticated
  using (public.my_role() in ('admin','staff'));
drop policy if exists materials_write on public.materials;
create policy materials_write on public.materials for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- overheads (ต้นทุนแฝง): admin เท่านั้น
drop policy if exists overheads_all on public.overheads;
create policy overheads_all on public.overheads for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- purchases / sales: admin เห็นทั้งหมด, staff เห็นเฉพาะที่ตัวเองออก
-- (การเพิ่มรายการทำผ่านฟังก์ชัน record_* เท่านั้น staff เพิ่ม/แก้/ลบตรงๆ ไม่ได้)
drop policy if exists purchases_select on public.purchases;
create policy purchases_select on public.purchases for select to authenticated
  using (public.my_role() = 'admin' or (public.my_role() = 'staff' and created_by = auth.uid()));
drop policy if exists purchases_admin_write on public.purchases;
create policy purchases_admin_write on public.purchases for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

drop policy if exists sales_select on public.sales;
create policy sales_select on public.sales for select to authenticated
  using (public.my_role() = 'admin' or (public.my_role() = 'staff' and created_by = auth.uid()));
drop policy if exists sales_admin_write on public.sales;
create policy sales_admin_write on public.sales for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- ไม่ให้คนที่ยังไม่ล็อกอินแตะอะไรเลย
revoke all on all tables in schema public from anon;
