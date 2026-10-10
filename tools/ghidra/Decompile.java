// Ghidra headless post-script: decompile functions at the given addresses.
// args: <out_file> <addr1> [addr2 ...]   (hex, with or without 0x)
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import java.io.*;

public class Decompile extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        PrintWriter out = new PrintWriter(new FileWriter(args[0]));
        DecompInterface ifc = new DecompInterface();
        ifc.openProgram(currentProgram);
        for (int i = 1; i < args.length; i++) {
            String s = args[i].toLowerCase().replace("0x", "");
            Address a = toAddr(Long.parseLong(s, 16));
            Function f = getFunctionContaining(a);
            if (f == null) {
                disassemble(a);
                f = createFunction(a, null);
            }
            out.println("// ===== " + args[i] + (f == null ? " (no function)" : " in " + f.getName() + " @ " + f.getEntryPoint()));
            if (f == null) continue;
            DecompileResults r = ifc.decompileFunction(f, 120, monitor);
            if (r != null && r.decompileCompleted()) out.println(r.getDecompiledFunction().getC());
            else out.println("// decompile failed: " + (r == null ? "null" : r.getErrorMessage()));
        }
        out.close();
    }
}
