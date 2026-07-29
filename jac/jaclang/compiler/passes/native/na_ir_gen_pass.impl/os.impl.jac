impl NaIRGenPass._emit_os_environ_call(
    name: str, nd: uni.FuncCall
) -> (ir.Value | None) {
    i8p = ir.IntType(8).as_pointer();
    i32 = ir.IntType(32);
    params = nd.params or [];

    if name == "get" {
        return self._emit_os_call("getenv", nd);
    }

    if name == "pop" {
        if not params {
            return None;
        }
        nameval = self._codegen_expr(params[0]);
        if nameval is None {
            return None;
        }
        getenv_fn = self._get_or_declare_extern("getenv", i8p, [i8p]);
        cur = self.builder.call(getenv_fn, [nameval], name="environ.pop.cur");
        func = self.builder.function;
        null_bb = func.append_basic_block(name="envpop.null");
        ok_bb = func.append_basic_block(name="envpop.ok");
        merge_bb = func.append_basic_block(name="envpop.merge");
        is_null = self.builder.icmp_signed(
            "==", cur, ir.Constant(i8p, None), name="envpop.isnull"
        );
        self.builder.cbranch(is_null, null_bb, ok_bb);

        self.builder.position_at_end(null_bb);
        null_res: ir.Value = ir.Constant(i8p, None);
        if len(params) >= 2 {
            _default_val = self._codegen_expr(params[1]);
            if _default_val is not None
            and isinstance(_default_val.type, ir.PointerType) {
                null_res = self._coerce_type(_default_val, i8p);

                self._emit_take_ref(null_res, op="environ_pop_default", loc="");
            }
        }
        self.builder.branch(merge_bb);
        null_end = self.builder.block;

        self.builder.position_at_end(ok_bb);
        copied = self._rc_strdup(cur, name="environ.pop.str");
        unset_fn = self._get_or_declare_extern("unsetenv", i32, [i8p]);
        self.builder.call(unset_fn, [nameval], name="environ.pop.unset");
        self.builder.branch(merge_bb);
        ok_end = self.builder.block;

        self.builder.position_at_end(merge_bb);
        phi = self.builder.phi(i8p, name="environ.pop.res");
        phi.add_incoming(null_res, null_end);
        phi.add_incoming(copied, ok_end);
        return phi;
    }

    return None;
}

impl NaIRGenPass._emit_os_call(name: str, nd: uni.FuncCall) -> (ir.Value | None) {
    i8 = ir.IntType(8);
    i8p = ir.IntType(8).as_pointer();
    i32 = ir.IntType(32);
    i64 = ir.IntType(64);
    params = nd.params or [];

    if name == "getpid" {
        fn = self._get_or_declare_extern("getpid", i32, []);
        pid = self.builder.call(fn, [], name="os.getpid");
        return self.builder.sext(pid, i64, name="os.getpid.i64");
    }

    if name == "getcwd" {
        buf = self.builder.alloca(ir.ArrayType(ir.IntType(8), 4096), name="os.cwd.buf");
        bufp = self.builder.gep(
            buf, [ir.Constant(i32, 0), ir.Constant(i32, 0)], name="os.cwd.bufp"
        );
        fn = self._get_or_declare_extern("getcwd", i8p, [i8p, i64]);
        self.builder.call(fn, [bufp, ir.Constant(i64, 4096)], name="os.getcwd");
        return self._rc_strdup(bufp, name="os.cwd.str");
    }

    if name == "getenv" {
        if not params {
            return None;
        }
        nameval = self._codegen_expr(params[0]);
        if nameval is None {
            return None;
        }
        fn = self._get_or_declare_extern("getenv", i8p, [i8p]);
        val = self.builder.call(fn, [nameval], name="os.getenv");

        func = self.builder.function;
        null_bb = func.append_basic_block(name="getenv.null");
        ok_bb = func.append_basic_block(name="getenv.ok");
        merge_bb = func.append_basic_block(name="getenv.merge");
        is_null = self.builder.icmp_signed(
            "==", val, ir.Constant(i8p, None), name="getenv.isnull"
        );
        self.builder.cbranch(is_null, null_bb, ok_bb);
        self.builder.position_at_end(null_bb);

        null_res: ir.Value = ir.Constant(i8p, None);
        if len(params) >= 2 {
            _default_val = self._codegen_expr(params[1]);
            if _default_val is not None
            and isinstance(_default_val.type, ir.PointerType) {
                null_res = self._coerce_type(_default_val, i8p);

                self._emit_take_ref(null_res, op="getenv_default", loc="");
            }
        }
        self.builder.branch(merge_bb);
        null_end = self.builder.block;
        self.builder.position_at_end(ok_bb);
        copied = self._rc_strdup(val, name="os.getenv.str");
        self.builder.branch(merge_bb);
        ok_end = self.builder.block;
        self.builder.position_at_end(merge_bb);
        phi = self.builder.phi(i8p, name="os.getenv.res");
        phi.add_incoming(null_res, null_end);
        phi.add_incoming(copied, ok_end);
        return phi;
    }

    if name == "system" {
        if not params {
            return None;
        }
        cmd = self._codegen_expr(params[0]);
        if cmd is None {
            return None;
        }
        fn = self._get_or_declare_extern("system", i32, [i8p]);
        rc = self.builder.call(fn, [cmd], name="os.system");
        return self.builder.sext(rc, i64, name="os.system.i64");
    }

    _single: dict[str, str] = {
        "chdir": "chdir",
        "rmdir": "rmdir",
        "remove": "unlink",
        "unlink": "unlink",

    };
    if name in _single and params {
        p = self._codegen_expr(params[0]);
        if p is None {
            return None;
        }
        fn = self._get_or_declare_extern(_single[name], i32, [i8p]);
        self.builder.call(fn, [p], name=f"os.{name}");
        return None;
    }

    if name == "mkdir" and params {
        p = self._codegen_expr(params[0]);
        if p is None {
            return None;
        }
        mode = ir.Constant(i32, 0o777);
        if len(params) >= 2 {
            mv = self._codegen_expr(params[1]);
            if mv is not None {
                mode = self._coerce_type(mv, i32);
            }
        }
        fn = self._get_or_declare_extern("mkdir", i32, [i8p, i32]);
        self.builder.call(fn, [p, mode], name="os.mkdir");
        return None;
    }

    if name == "makedirs" and params {
        p = self._codegen_expr(params[0]);
        if p is None {
            return None;
        }
        mode = ir.Constant(i32, 0o777);
        if len(params) >= 2 {
            mv = self._codegen_expr(params[1]);
            if mv is not None {
                mode = self._coerce_type(mv, i32);
            }
        }
        strlen_fn = self._get_or_declare_extern("strlen", i64, [i8p]);
        memcpy_fn = self._get_or_declare_extern("memcpy", i8p, [i8p, i8p, i64]);
        mkdir_fn = self._get_or_declare_extern("mkdir", i32, [i8p, i32]);
        malloc_fn = self._get_or_declare_extern("malloc", i8p, [i64]);
        free_fn = self._get_or_declare_extern("free", ir.VoidType(), [i8p]);
        plen = self.builder.call(strlen_fn, [p], name="mkdirs.len");

        copy_n = self.builder.add(plen, ir.Constant(i64, 1), name="mkdirs.copyn");
        bufp = self.builder.call(malloc_fn, [copy_n], name="mkdirs.buf");
        self.builder.call(memcpy_fn, [bufp, p, copy_n]);
        i_ptr = self.builder.alloca(i64, name="mkdirs.i");

        self.builder.store(ir.Constant(i64, 1), i_ptr);
        func = self.builder.function;
        head_bb = func.append_basic_block(name="mkdirs.head");
        body_bb = func.append_basic_block(name="mkdirs.body");
        slash_bb = func.append_basic_block(name="mkdirs.slash");
        cont_bb = func.append_basic_block(name="mkdirs.cont");
        after_bb = func.append_basic_block(name="mkdirs.after");
        self.builder.branch(head_bb);
        self.builder.position_at_end(head_bb);
        i_val = self.builder.load(i_ptr, name="mkdirs.iv");
        loop_cond = self.builder.icmp_signed("<", i_val, plen, name="mkdirs.cond");
        self.builder.cbranch(loop_cond, body_bb, after_bb);
        self.builder.position_at_end(body_bb);
        ch_ptr = self.builder.gep(bufp, [i_val], name="mkdirs.chp");
        ch = self.builder.load(ch_ptr, name="mkdirs.ch");
        is_slash = self.builder.icmp_signed(
            "==", ch, ir.Constant(i8, 47), name="mkdirs.issl"
        );
        self.builder.cbranch(is_slash, slash_bb, cont_bb);
        self.builder.position_at_end(slash_bb);
        self.builder.store(ir.Constant(i8, 0), ch_ptr);
        self.builder.call(mkdir_fn, [bufp, mode], name="mkdirs.mid");
        self.builder.store(ir.Constant(i8, 47), ch_ptr);
        self.builder.branch(cont_bb);
        self.builder.position_at_end(cont_bb);
        next_i = self.builder.add(i_val, ir.Constant(i64, 1), name="mkdirs.next");
        self.builder.store(next_i, i_ptr);
        self.builder.branch(head_bb);
        self.builder.position_at_end(after_bb);

        self.builder.call(mkdir_fn, [bufp, mode], name="mkdirs.leaf");
        self.builder.call(free_fn, [bufp], name="mkdirs.free");
        return None;
    }

    if name == "listdir" and params {
        p = self._codegen_expr(params[0]);
        if p is None {
            return None;
        }
        layout = self._stat_offsets();
        i8p_l = ir.IntType(8).as_pointer();
        self._emit_list_helpers("ptr", i8p_l);
        helpers = self.list_helpers["ptr"];
        _loc = f"{os.path.basename(self.ir_in.loc.mod_path)}:{nd.loc.first_line
            if nd.loc
            else 0}";

        opendir_fn = self._get_or_declare_extern("opendir", i8p, [i8p]);
        readdir_fn = self._get_or_declare_extern("readdir", i8p, [i8p]);
        closedir_fn = self._get_or_declare_extern("closedir", i32, [i8p]);

        listv = self._rc_call_with_ctx(
            helpers["new"], [], op="new", loc=_loc, name="listdir.new"
        );
        dirp = self.builder.call(opendir_fn, [p], name="listdir.opendir");

        func = self.builder.function;
        loop_bb = func.append_basic_block(name="listdir.loop");
        body_bb = func.append_basic_block(name="listdir.body");
        keep_bb = func.append_basic_block(name="listdir.keep");
        close_bb = func.append_basic_block(name="listdir.close");
        done_bb = func.append_basic_block(name="listdir.done");

        opened = self.builder.icmp_signed(
            "!=", dirp, ir.Constant(i8p, None), name="listdir.opened"
        );
        self.builder.cbranch(opened, loop_bb, done_bb);

        self.builder.position_at_end(loop_bb);
        ent = self.builder.call(readdir_fn, [dirp], name="listdir.readdir");
        more = self.builder.icmp_signed(
            "!=", ent, ir.Constant(i8p, None), name="listdir.more"
        );
        self.builder.cbranch(more, body_bb, close_bb);

        self.builder.position_at_end(body_bb);
        namep = self.builder.gep(
            ent, [ir.Constant(i64, layout["dname"])], name="listdir.namep"
        );
        b0 = self.builder.load(namep, name="listdir.b0");
        p1 = self.builder.gep(namep, [ir.Constant(i64, 1)], name="listdir.p1");
        b1 = self.builder.load(p1, name="listdir.b1");
        p2 = self.builder.gep(namep, [ir.Constant(i64, 2)], name="listdir.p2");
        b2 = self.builder.load(p2, name="listdir.b2");
        dot = ir.Constant(i8, 46);
        nul = ir.Constant(i8, 0);
        is_dot0 = self.builder.icmp_signed("==", b0, dot, name="listdir.isdot0");
        is_end1 = self.builder.icmp_signed("==", b1, nul, name="listdir.isend1");
        is_dot1 = self.builder.icmp_signed("==", b1, dot, name="listdir.isdot1");
        is_end2 = self.builder.icmp_signed("==", b2, nul, name="listdir.isend2");
        dotdot = self.builder.and_(is_dot1, is_end2, name="listdir.dotdot");
        selfref = self.builder.or_(is_end1, dotdot, name="listdir.selfref");
        is_self = self.builder.and_(is_dot0, selfref, name="listdir.selfentry");
        self.builder.cbranch(is_self, loop_bb, keep_bb);

        self.builder.position_at_end(keep_bb);
        nameval = self._rc_strdup(namep, name="listdir.name");
        self._rc_call_with_ctx(
            helpers["append"], [listv, nameval], op="list_init", loc=_loc
        );
        if self._is_owned(nameval) {
            self._emit_rc_release_simple(nameval, op="list_init", loc=_loc);
        }
        self.builder.branch(loop_bb);

        self.builder.position_at_end(close_bb);
        self.builder.call(closedir_fn, [dirp], name="listdir.closedir");
        self.builder.branch(done_bb);

        self.builder.position_at_end(done_bb);
        return listv;
    }

    if name == "rename" and len(params) >= 2 {
        src = self._codegen_expr(params[0]);
        dst = self._codegen_expr(params[1]);
        if src is None or dst is None {
            return None;
        }
        fn = self._get_or_declare_extern("rename", i32, [i8p, i8p]);
        self.builder.call(fn, [src, dst], name="os.rename");
        return None;
    }

    return None;
}

impl NaIRGenPass._emit_ospath_call(name: str, nd: uni.FuncCall) -> (ir.Value | None) {
    i8 = ir.IntType(8);
    i8p = ir.IntType(8).as_pointer();
    i32 = ir.IntType(32);
    i64 = ir.IntType(64);
    params = nd.params or [];

    if name == "join" and params {
        acc = self._codegen_expr(params[0]);
        if acc is None {
            return None;
        }
        sep = self._make_global_string("/", name_prefix=".ospath.sep");
        strlen_fn = self._get_or_declare_extern("strlen", i64, [i8p]);
        for idx in range(1, len(params)) {
            b = self._codegen_expr(params[idx]);
            if b is None {
                return None;
            }

            b0 = self.builder.load(b, name="join.b0");
            b_abs = self.builder.icmp_signed(
                "==", b0, ir.Constant(i8, 47), name="join.babs"
            );

            alen = self.builder.call(strlen_fn, [acc], name="join.alen");
            a_empty = self.builder.icmp_signed(
                "==", alen, ir.Constant(i64, 0), name="join.aempty"
            );
            last_idx = self.builder.sub(alen, ir.Constant(i64, 1), name="join.lastidx");
            last_ptr = self.builder.gep(acc, [last_idx], name="join.lastptr");
            last_ch = self.builder.load(last_ptr, name="join.lastch");
            a_slash = self.builder.icmp_signed(
                "==", last_ch, ir.Constant(i8, 47), name="join.aslash"
            );

            no_sep = self.builder.or_(a_empty, a_slash, name="join.nosep0");
            no_sep = self.builder.or_(no_sep, b_abs, name="join.nosep");
            with_sep = self._emit_binary_op(Tok.PLUS, acc, sep);
            joined_sep = self._emit_binary_op(Tok.PLUS, with_sep, b);
            joined_nosep = self._emit_binary_op(Tok.PLUS, acc, b);

            picked = self.builder.select(
                no_sep, joined_nosep, joined_sep, name="join.pick"
            );
            acc = self.builder.select(b_abs, b, picked, name="join.acc");
        }
        return acc;
    }

    if name == "basename" and params {
        p = self._codegen_expr(params[0]);
        if p is None {
            return None;
        }
        strrchr_fn = self._get_or_declare_extern("strrchr", i8p, [i8p, i32]);
        hit = self.builder.call(strrchr_fn, [p, ir.Constant(i32, 47)], name="bn.hit");
        is_null = self.builder.icmp_signed(
            "==", hit, ir.Constant(i8p, None), name="bn.isnull"
        );

        after = self.builder.gep(hit, [ir.Constant(i64, 1)], name="bn.after");
        start = self.builder.select(is_null, p, after, name="bn.start");
        return self._rc_strdup(start, name="bn.str");
    }

    if name == "dirname" and params {
        p = self._codegen_expr(params[0]);
        if p is None {
            return None;
        }
        strrchr_fn = self._get_or_declare_extern("strrchr", i8p, [i8p, i32]);
        hit = self.builder.call(strrchr_fn, [p, ir.Constant(i32, 47)], name="dn.hit");
        func = self.builder.function;
        none_bb = func.append_basic_block(name="dn.none");
        cut_bb = func.append_basic_block(name="dn.cut");
        merge_bb = func.append_basic_block(name="dn.merge");
        is_null = self.builder.icmp_signed(
            "==", hit, ir.Constant(i8p, None), name="dn.isnull"
        );
        self.builder.cbranch(is_null, none_bb, cut_bb);
        self.builder.position_at_end(none_bb);
        empty_res = self._make_global_string("", name_prefix=".dirname.empty");
        self.builder.branch(merge_bb);
        none_end = self.builder.block;
        self.builder.position_at_end(cut_bb);

        hit_i = self.builder.ptrtoint(hit, i64, name="dn.hiti");
        p_i = self.builder.ptrtoint(p, i64, name="dn.pi");
        dlen = self.builder.sub(hit_i, p_i, name="dn.len");
        bufsz = self.builder.add(dlen, ir.Constant(i64, 1), name="dn.bufsz");
        self._set_rc_ctx("dirname", "");
        raw = self._rc_alloc(bufsz, name="dn.raw");
        self._clear_rc_ctx();
        memcpy_fn = self._get_or_declare_extern("memcpy", i8p, [i8p, i8p, i64]);
        self.builder.call(memcpy_fn, [raw, p, dlen]);
        nul_ptr = self.builder.gep(raw, [dlen], name="dn.nulptr");
        self.builder.store(ir.Constant(i8, 0), nul_ptr);
        self._emit_set_type_tag(self.builder, raw, "str");
        self._mark_owned(raw);
        self.builder.branch(merge_bb);
        cut_end = self.builder.block;
        self.builder.position_at_end(merge_bb);
        phi = self.builder.phi(i8p, name="dn.res");
        phi.add_incoming(empty_res, none_end);
        phi.add_incoming(raw, cut_end);
        return phi;
    }

    if name == "realpath" and params {
        p = self._codegen_expr(params[0]);
        if p is None {
            return None;
        }
        buf = self.builder.alloca(ir.ArrayType(i8, 4096), name="rp.buf");
        bufp = self.builder.gep(
            buf, [ir.Constant(i32, 0), ir.Constant(i32, 0)], name="rp.bufp"
        );
        fn = self._get_or_declare_extern("realpath", i8p, [i8p, i8p]);
        res = self.builder.call(fn, [p, bufp], name="rp.call");
        func = self.builder.function;
        null_bb = func.append_basic_block(name="rp.null");
        ok_bb = func.append_basic_block(name="rp.ok");
        merge_bb = func.append_basic_block(name="rp.merge");
        is_null = self.builder.icmp_signed(
            "==", res, ir.Constant(i8p, None), name="rp.isnull"
        );
        self.builder.cbranch(is_null, null_bb, ok_bb);
        self.builder.position_at_end(null_bb);
        fallback = self._rc_strdup(p, name="rp.fallback");
        self.builder.branch(merge_bb);
        null_end = self.builder.block;
        self.builder.position_at_end(ok_bb);
        resolved = self._rc_strdup(bufp, name="rp.str");
        self.builder.branch(merge_bb);
        ok_end = self.builder.block;
        self.builder.position_at_end(merge_bb);
        phi = self.builder.phi(i8p, name="rp.res");
        phi.add_incoming(fallback, null_end);
        phi.add_incoming(resolved, ok_end);
        return phi;
    }

    if name == "exists" and params {
        p = self._codegen_expr(params[0]);
        if p is None {
            return None;
        }
        fn = self._get_or_declare_extern("access", i32, [i8p, i32]);
        rc = self.builder.call(fn, [p, ir.Constant(i32, 0)], name="ospath.access");
        return self.builder.icmp_signed(
            "==", rc, ir.Constant(i32, 0), name="ospath.exists"
        );
    }

    if name == "islink" and params {
        p = self._codegen_expr(params[0]);
        if p is None {
            return None;
        }
        layout = self._stat_offsets();
        mode = self._emit_stat_field(p, layout["mode"], layout["mode_w"], True);
        if mode is None {
            return None;
        }
        ok = self.builder.icmp_signed(
            ">=", mode, ir.Constant(i64, 0), name="ospath.islink.ok"
        );
        fmt = self.builder.and_(
            mode, ir.Constant(i64, 0o170000), name="ospath.islink.fmt"
        );
        kind = self.builder.icmp_signed(
            "==", fmt, ir.Constant(i64, 0o120000), name="ospath.islink.kind"
        );
        return self.builder.and_(ok, kind, name="ospath.islink");
    }

    if (name == "isfile" or name == "isdir") and params {
        p = self._codegen_expr(params[0]);
        if p is None {
            return None;
        }
        layout = self._stat_offsets();
        mode = self._emit_stat_field(p, layout["mode"], layout["mode_w"]);
        if mode is None {
            return None;
        }
        ok = self.builder.icmp_signed(
            ">=", mode, ir.Constant(i64, 0), name=f"ospath.{name}.ok"
        );
        fmt = self.builder.and_(
            mode, ir.Constant(i64, 0o170000), name=f"ospath.{name}.fmt"
        );
        want = 0o040000 if name == "isdir" else 0o100000;
        kind = self.builder.icmp_signed(
            "==", fmt, ir.Constant(i64, want), name=f"ospath.{name}.kind"
        );
        return self.builder.and_(ok, kind, name=f"ospath.{name}");
    }

    if name in ["getsize", "inode", "nlink", "blocks", "getmtime", "device"] and params {
        p = self._codegen_expr(params[0]);
        if p is None {
            return None;
        }
        layout = self._stat_offsets();
        field = layout["size"];
        width = 64;
        if name == "inode" {
            field = layout["ino"];
            width = layout["ino_w"];
        } elif name == "device" {
            field = layout["dev"];
            width = layout["dev_w"];
        } elif name == "nlink" {
            field = layout["nlink"];
            width = layout["nlink_w"];
        } elif name == "blocks" {
            field = layout["blocks"];
        } elif name == "getmtime" {
            field = layout["mtime"];
        }
        value = self._emit_stat_field(p, field, width);
        if value is None {
            return None;
        }
        if name == "getmtime" {
            return self.builder.sitofp(
                value, ir.DoubleType(), name="ospath.getmtime"
            );
        }
        return value;
    }

    if name == "freebytes" and params {
        p = self._codegen_expr(params[0]);
        if p is None {
            return None;
        }
        layout = self._stat_offsets();
        buf = self.builder.alloca(
            ir.ArrayType(i8, layout["fsbufsize"]), name="statfs.buf"
        );
        bufp = self.builder.gep(
            buf, [ir.Constant(i32, 0), ir.Constant(i32, 0)], name="statfs.bufp"
        );
        fn = self._get_or_declare_extern(layout["fssym"], i32, [i8p, i8p]);
        rc = self.builder.call(fn, [p, bufp], name="statfs.call");
        ok = self.builder.icmp_signed(
            "==", rc, ir.Constant(i32, 0), name="statfs.ok"
        );
        unit_p8 = self.builder.gep(
            bufp, [ir.Constant(i64, layout["fs_bsize"])], name="statfs.unitp8"
        );
        unit_p = self.builder.bitcast(
            unit_p8,
            ir.IntType(layout["fs_bsize_w"]).as_pointer(),
            name="statfs.unitp"
        );
        unit_raw = self.builder.load(unit_p, name="statfs.unit.raw");
        unit = unit_raw if layout["fs_bsize_w"] == 64 else self.builder.zext(
            unit_raw, i64, name="statfs.unit"
        );
        avail_p8 = self.builder.gep(
            bufp, [ir.Constant(i64, layout["fs_bavail"])], name="statfs.availp8"
        );
        avail_p = self.builder.bitcast(
            avail_p8, i64.as_pointer(), name="statfs.availp"
        );
        avail = self.builder.load(avail_p, name="statfs.avail");
        total = self.builder.mul(unit, avail, name="statfs.total");
        return self.builder.select(
            ok, total, ir.Constant(i64, -1), name="ospath.freebytes"
        );
    }

    return None;
}

"""Byte offsets of the `struct stat` and `struct statfs` fields we read.

The layouts differ by platform and, on Linux, by architecture, so they are
selected from the target triple rather than assumed. Getting one wrong reads a
neighbouring field and returns a confident wrong number, so every offset here is
checked by tests against the values the C library itself reports.
"""
impl NaIRGenPass._stat_offsets -> dict {
    triple = str(self.llvm_module.triple or "").lower();
    is_darwin = ("darwin" in triple) or ("apple" in triple) or ("macos" in triple);
    is_arm = ("aarch64" in triple) or ("arm64" in triple);

    if is_darwin {
        suffix = "$INODE64" if "x86_64" in triple else "";
        return {
            "sym": "stat" + suffix,
            "lsym": "lstat" + suffix,
            "fssym": "statfs" + suffix,
            "bufsize": 256,
            "fsbufsize": 2304,
            "dev": 0, "dev_w": 32,
            "ino": 8, "ino_w": 64,
            "nlink": 6, "nlink_w": 16,
            "mode": 4, "mode_w": 16,
            "size": 96,
            "blocks": 104,
            "mtime": 48,
            "fs_bsize": 0, "fs_bsize_w": 32,
            "fs_bavail": 24,
            "dname": 21
        };
    }

    if is_arm {
        return {
            "sym": "stat", "lsym": "lstat", "fssym": "statfs",
            "bufsize": 256, "fsbufsize": 256,
            "dev": 0, "dev_w": 64,
            "ino": 8, "ino_w": 64,
            "nlink": 20, "nlink_w": 32,
            "mode": 16, "mode_w": 32,
            "size": 48,
            "blocks": 64,
            "mtime": 88,
            "fs_bsize": 8, "fs_bsize_w": 64,
            "fs_bavail": 32,
            "dname": 19
        };
    }

    return {
        "sym": "stat", "lsym": "lstat", "fssym": "statfs",
        "bufsize": 256, "fsbufsize": 256,
        "dev": 0, "dev_w": 64,
        "ino": 8, "ino_w": 64,
        "nlink": 16, "nlink_w": 64,
        "mode": 24, "mode_w": 32,
        "size": 48,
        "blocks": 64,
        "mtime": 88,
        "fs_bsize": 8, "fs_bsize_w": 64,
        "fs_bavail": 32,
        "dname": 19
    };
}

"""Stats `pathval` and loads one field, widened to i64. Yields -1 if stat fails."""
impl NaIRGenPass._emit_stat_field(
    pathval: ir.Value, offset: int, width: int, use_lstat: bool = False
) -> (ir.Value | None) {
    i8 = ir.IntType(8);
    i8p = ir.IntType(8).as_pointer();
    i32 = ir.IntType(32);
    i64 = ir.IntType(64);
    layout = self._stat_offsets();
    sym = layout["lsym"] if use_lstat else layout["sym"];

    buf = self.builder.alloca(
        ir.ArrayType(i8, layout["bufsize"]), name="statfield.buf"
    );
    bufp = self.builder.gep(
        buf, [ir.Constant(i32, 0), ir.Constant(i32, 0)], name="statfield.bufp"
    );
    fn = self._get_or_declare_extern(sym, i32, [i8p, i8p]);
    rc = self.builder.call(fn, [pathval, bufp], name="statfield.call");
    ok = self.builder.icmp_signed(
        "==", rc, ir.Constant(i32, 0), name="statfield.ok"
    );
    fieldp8 = self.builder.gep(
        bufp, [ir.Constant(i64, offset)], name="statfield.p8"
    );
    fieldp = self.builder.bitcast(
        fieldp8, ir.IntType(width).as_pointer(), name="statfield.p"
    );
    raw = self.builder.load(fieldp, name="statfield.raw");
    wide = raw if width == 64 else self.builder.zext(raw, i64, name="statfield.wide");
    return self.builder.select(
        ok, wide, ir.Constant(i64, -1), name="statfield.res"
    );
}
